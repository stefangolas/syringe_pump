"""Flask control server for one or more A4988-driven syringe pump motors.

Motors are declared on the command line, one --motor per motor:

    motor_server.py --motor a:22,23,17,27,25 --motor b:5,6,13,19,26

Each gets its own id, its own pins, its own stop flag and its own lock, so the
two are genuinely independent: commanding or stopping one never touches the
other. The id appears in the URL:

    POST /motor/a/run     {"steps": 600, "direction": "clockwise", ...}
    POST /motor/a/stop
    GET  /motor/a/status
    GET  /motors

The original single-motor routes (/run_motor, /stop_motor, /status) remain and
act on the FIRST declared motor, so existing clients keep working unchanged.

Run this file by path, not with -m: it does `from A4988 import A4988Nema`,
which needs this directory on sys.path.
"""
from flask import Flask, request, jsonify
import RPi.GPIO as GPIO
from A4988 import A4988Nema
import argparse
import os
import threading
import traceback
from flask_caching import Cache


app = Flask(__name__)
# Redis on the instrument, where the systemd unit Requires=redis-server. The
# override exists so the server can be exercised off-device -- with
# PUMP_CACHE_TYPE=SimpleCache it runs, and the tests drive it, without Redis.
app.config['CACHE_TYPE'] = os.environ.get('PUMP_CACHE_TYPE', 'RedisCache')
cache = Cache(app)


def _stop_requested(cache, key):
    """Read a stop flag back, tolerating whatever the cache hands over.

    The value can come back as a str, as bytes from a raw Redis client, or as
    None when the key has expired; none of those should raise.
    """
    value = cache.get(key)
    if isinstance(value, bytes):
        value = value.decode("utf-8", "replace")
    if isinstance(value, str):
        return value.strip().lower() in ("true", "1", "yes")
    return bool(value)


def parse_motor_spec(spec):
    """Parse 'a:22,23,17,27,25' or 'a:22,23' into (id, dir, step, mode_pins).

    Two pins means MS1/MS2/MS3 are strapped in hardware, so (-1,-1,-1) is
    passed and the driver leaves those pins alone.
    """
    if ":" not in spec:
        raise argparse.ArgumentTypeError(
            "motor {!r} is not <id>:<pins>".format(spec))
    motor_id, _, pin_text = spec.partition(":")
    if not motor_id:
        raise argparse.ArgumentTypeError("motor {!r} has an empty id".format(spec))
    try:
        pins = [int(p) for p in pin_text.split(",")]
    except ValueError:
        raise argparse.ArgumentTypeError(
            "motor {!r} has a non-numeric pin".format(spec))
    if len(pins) == 2:
        pins += [-1, -1, -1]
    if len(pins) != 5:
        raise argparse.ArgumentTypeError(
            "motor {!r} needs 2 or 5 pins, got {}".format(spec, len(pins)))
    return motor_id, pins[0], pins[1], tuple(pins[2:])


class Motor:
    """One physical motor: its pins, its stop flag and its lock."""

    def __init__(self, motor_id, dir_pin, step_pin, mode_pins, cache):
        self.id = motor_id
        self.dir_pin = dir_pin
        self.step_pin = step_pin
        self.mode_pins = mode_pins
        self.cache = cache
        # Namespaced per motor. One shared 'stop_motor' key would mean stopping
        # either motor halted both.
        self.stop_key = "stop_motor:{}".format(motor_id)
        # Serialises commands to THIS motor only. Flask's server is threaded,
        # so without a lock two overlapping requests for one motor would drive
        # the same STEP pin from two threads and the step count would be
        # meaningless. Two motors hold two different locks and so still run at
        # the same time, which is the entire point of the id.
        self.lock = threading.Lock()
        self.motor = A4988Nema(dir_pin, step_pin, mode_pins, cache,
                               stop_key=self.stop_key)

    def describe(self):
        return {
            "id": self.id,
            "dir_pin": self.dir_pin,
            "step_pin": self.step_pin,
            "mode_pins": list(self.mode_pins),
            "busy": self.lock.locked(),
        }


class MotorServer:
    def __init__(self, motor_specs=None, cache=cache):
        self.cache = cache
        self.motors = {}
        self.order = []

        if not motor_specs:
            # The historical single-motor pinout, so running this file with no
            # arguments still works.
            motor_specs = ["a:22,23,17,27,25"]

        for spec in motor_specs:
            if isinstance(spec, str):
                motor_id, dir_pin, step_pin, mode_pins = parse_motor_spec(spec)
            else:
                motor_id, dir_pin, step_pin, mode_pins = spec
            if motor_id in self.motors:
                raise ValueError("motor id {!r} declared twice".format(motor_id))
            self.motors[motor_id] = Motor(motor_id, dir_pin, step_pin,
                                          mode_pins, cache)
            self.order.append(motor_id)

        # Every alias route resolves to this one.
        self.default_id = self.order[0]
        self.setup_routes()

    # --- handlers ---------------------------------------------------------

    def _unknown(self, motor_id):
        return jsonify({
            "status": "error",
            "message": "unknown motor {!r}; configured: {}".format(
                motor_id, ", ".join(self.order)),
        }), 404

    def _run(self, motor_id):
        motor = self.motors.get(motor_id)
        if motor is None:
            return self._unknown(motor_id)

        data = request.get_json(silent=True) or {}
        steps = data.get('steps', 200)
        direction = data.get('direction', 'clockwise')
        steptype = data.get('steptype', '1/8')
        stepdelay = data.get('stepdelay', 0.0005)

        try:
            steps = int(steps)
            stepdelay = float(stepdelay)
        except (TypeError, ValueError):
            return jsonify({
                "status": "error",
                "message": "steps must be an integer and stepdelay a number",
            }), 400
        if steps < 0:
            return jsonify({"status": "error",
                            "message": "steps must not be negative"}), 400

        clockwise = str(direction).lower() == 'clockwise'

        # Non-blocking: a second command for a motor that is already moving is
        # a caller mistake, and queueing it behind a 20000-step move would hold
        # the HTTP request open for minutes.
        if not motor.lock.acquire(blocking=False):
            return jsonify({
                "status": "busy",
                "motor": motor_id,
                "message": "motor {0} is already running; POST /motor/{0}/stop first".format(
                    motor_id),
            }), 409

        try:
            # Clear THIS motor's stop flag; the other motor's is untouched.
            self.cache.set(motor.stop_key, 'False')
            motor.motor.motor_go(clockwise=clockwise, steptype=steptype,
                                 steps=steps, stepdelay=stepdelay)
            stopped = _stop_requested(self.cache, motor.stop_key)
            return jsonify({
                "status": "stopped" if stopped else "success",
                "motor": motor_id,
                "steps": steps,
                "direction": "clockwise" if clockwise else "counter-clockwise",
                "message": "motor {} {} {} steps {}".format(
                    motor_id,
                    "stopped during" if stopped else "ran",
                    steps,
                    "clockwise" if clockwise else "counter-clockwise"),
            }), 200
        except ValueError as bad_request:
            # An invalid steptype or motor_type is the caller's problem, not
            # the server's, so say so with a 400 rather than a 500.
            return jsonify({"status": "error", "motor": motor_id,
                            "message": str(bad_request)}), 400
        except Exception:
            tb = traceback.format_exc()
            print(tb)
            return jsonify({"status": "error", "motor": motor_id,
                            "message": tb}), 500
        finally:
            motor.lock.release()

    def _stop(self, motor_id):
        motor = self.motors.get(motor_id)
        if motor is None:
            return self._unknown(motor_id)
        self.cache.set(motor.stop_key, 'True')
        return jsonify({
            "status": "success",
            "motor": motor_id,
            "message": "stop requested for motor {}".format(motor_id),
        }), 200

    def _status(self, motor_id):
        motor = self.motors.get(motor_id)
        if motor is None:
            return self._unknown(motor_id)
        info = motor.describe()
        info["status"] = "running" if info["busy"] else "idle"
        info["stop_requested"] = _stop_requested(self.cache, motor.stop_key)
        return jsonify(info), 200

    # --- routes -----------------------------------------------------------

    def setup_routes(self):
        @app.route('/motors', methods=['GET'])
        def motors():
            return jsonify({
                "status": "running",
                "default": self.default_id,
                "motors": [self.motors[m].describe() for m in self.order],
            }), 200

        @app.route('/motor/<motor_id>/run', methods=['POST'])
        def run_one(motor_id):
            return self._run(motor_id)

        @app.route('/motor/<motor_id>/stop', methods=['POST'])
        def stop_one(motor_id):
            return self._stop(motor_id)

        @app.route('/motor/<motor_id>/status', methods=['GET'])
        def status_one(motor_id):
            return self._status(motor_id)

        # --- single-motor aliases, kept for existing clients --------------
        @app.route('/run_motor', methods=['POST'])
        def run_motor():
            return self._run(self.default_id)

        @app.route('/stop_motor', methods=['POST'])
        def stop_motor():
            return self._stop(self.default_id)

        @app.route('/status', methods=['GET'])
        def status():
            # Deliberately unchanged in shape: check_status() only looks for
            # this to answer at all, so it stays a flat {"status": ...}.
            return jsonify({"status": "running"}), 200

    def run(self, host='0.0.0.0', port=5000):
        try:
            # threaded=True is what lets two motors move at once. It is Flask's
            # default; stating it makes the dependency explicit rather than
            # incidental to a default that could change.
            app.run(host=host, port=port, threaded=True)
        finally:
            GPIO.cleanup()


def main():
    parser = argparse.ArgumentParser(
        description='Run the syringe pump motor server')
    parser.add_argument('--host', default='0.0.0.0', help='Host to run the server on')
    parser.add_argument('--port', type=int, default=5000, help='Port to run the server on')
    parser.add_argument(
        '--motor', action='append', dest='motors', metavar='ID:PINS',
        help='A motor, as <id>:<dir>,<step>,<ms1>,<ms2>,<ms3> (or <id>:<dir>,<step> '
             'when MS1-MS3 are strapped in hardware). Repeat for each motor.')
    args = parser.parse_args()

    server = MotorServer(motor_specs=args.motors)

    print("Starting motor server on {}:{}".format(args.host, args.port))
    for motor_id in server.order:
        motor = server.motors[motor_id]
        print("  motor {}: dir={} step={} mode={}".format(
            motor_id, motor.dir_pin, motor.step_pin, motor.mode_pins))
    server.run(host=args.host, port=args.port)


if __name__ == '__main__':
    main()
