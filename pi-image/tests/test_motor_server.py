"""Exercise the motor server's two-motor behaviour without a Raspberry Pi.

RPi.GPIO is shimmed, so this runs anywhere. What it proves is exactly what the
multi-motor work is for and what no amount of reading can confirm:

  * two motors move AT THE SAME TIME, rather than one blocking the other;
  * stopping one motor leaves the other running;
  * a second command to a busy motor is refused instead of interleaving steps
    on the same STEP pin;
  * each motor drives only its own pins.

Run:  python pi-image/tests/test_motor_server.py
"""
import os
import sys
import threading
import time
import types
import unittest


REPO_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
PKG_DIR = os.path.join(REPO_ROOT, "syringe_pump")


def install_gpio_shim():
    """A fake RPi.GPIO that records every edge, with a per-pin lock check.

    The real module raises on non-Pi hardware, so the import chain cannot be
    tested without this. It is deliberately strict about setmode/setup: a shim
    that accepts anything would hide the kind of bug it exists to catch.
    """
    gpio = types.ModuleType("RPi.GPIO")
    gpio.BCM = "BCM"
    gpio.OUT = "OUT"
    gpio.HIGH = True
    gpio.LOW = False
    gpio.edges = []           # (pin, value) in order
    gpio.configured = set()
    gpio.lock = threading.Lock()

    def setmode(mode):
        assert mode == "BCM", mode

    def setwarnings(_flag):
        pass

    def setup(pin, mode):
        pins = pin if isinstance(pin, (tuple, list)) else [pin]
        with gpio.lock:
            for p in pins:
                gpio.configured.add(p)

    def output(pin, value):
        pins = pin if isinstance(pin, (tuple, list)) else [pin]
        values = value if isinstance(value, (tuple, list)) else [value] * len(pins)
        with gpio.lock:
            for p, v in zip(pins, values):
                assert p in gpio.configured, "pin %r driven before setup" % (p,)
                gpio.edges.append((p, bool(v)))

    def cleanup():
        pass

    gpio.setmode = setmode
    gpio.setwarnings = setwarnings
    gpio.setup = setup
    gpio.output = output
    gpio.cleanup = cleanup

    rpi = types.ModuleType("RPi")
    rpi.GPIO = gpio
    sys.modules["RPi"] = rpi
    sys.modules["RPi.GPIO"] = gpio
    return gpio


GPIO = install_gpio_shim()
os.environ["PUMP_CACHE_TYPE"] = "SimpleCache"
sys.path.insert(0, PKG_DIR)
import motor_server  # noqa: E402


MOTORS = ["a:22,23,17,27,25", "b:5,6,13,19,26"]


class TwoMotorServerTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.server = motor_server.MotorServer(motor_specs=MOTORS)
        motor_server.app.config["TESTING"] = True
        cls.client = motor_server.app.test_client()

    def setUp(self):
        del GPIO.edges[:]
        for motor_id in self.server.order:
            self.server.cache.set(self.server.motors[motor_id].stop_key, "False")

    # --- configuration ----------------------------------------------------

    def test_both_motors_registered_with_their_own_pins(self):
        body = self.client.get("/motors").get_json()
        self.assertEqual(body["default"], "a")
        by_id = {m["id"]: m for m in body["motors"]}
        self.assertEqual(by_id["a"]["step_pin"], 23)
        self.assertEqual(by_id["b"]["step_pin"], 6)
        self.assertEqual(by_id["a"]["mode_pins"], [17, 27, 25])
        self.assertEqual(by_id["b"]["mode_pins"], [13, 19, 26])

    def test_separate_stop_keys(self):
        self.assertNotEqual(self.server.motors["a"].stop_key,
                            self.server.motors["b"].stop_key)

    def test_strapped_mode_pins_become_minus_one(self):
        self.assertEqual(motor_server.parse_motor_spec("c:7,8"),
                         ("c", 7, 8, (-1, -1, -1)))

    def test_bad_specs_rejected(self):
        for bad in ("nocolon", ":22,23", "a:22", "a:22,23,17,27", "a:x,y"):
            with self.assertRaises(Exception, msg=bad):
                motor_server.parse_motor_spec(bad)

    def test_unknown_motor_is_404(self):
        response = self.client.post("/motor/z/run", json={"steps": 1})
        self.assertEqual(response.status_code, 404)
        self.assertIn("configured", response.get_json()["message"])

    # --- independence -----------------------------------------------------

    def test_each_motor_drives_only_its_own_step_pin(self):
        self.client.post("/motor/a/run",
                         json={"steps": 4, "steptype": "Half", "stepdelay": 0})
        stepped = {pin for pin, _ in GPIO.edges}
        self.assertIn(23, stepped)
        self.assertNotIn(6, stepped, "motor a drove motor b's STEP pin")

    def test_two_motors_run_concurrently(self):
        """The load-bearing test: wall time must be one move, not two.

        Each move is 20 steps with a 5 ms step delay, i.e. two delays per step
        = ~200 ms. Run serially they would take ~400 ms; run concurrently,
        ~200 ms. The threshold sits between the two with room for scheduler
        noise, so this fails if the motors ever serialise on a shared lock.
        """
        results = {}

        def drive(motor_id):
            start = time.monotonic()
            response = self.client.post(
                "/motor/%s/run" % motor_id,
                json={"steps": 20, "steptype": "Half", "stepdelay": 0.005})
            results[motor_id] = (response.status_code, time.monotonic() - start)

        threads = [threading.Thread(target=drive, args=(m,)) for m in ("a", "b")]
        started = time.monotonic()
        for t in threads:
            t.start()
        for t in threads:
            t.join(timeout=30)
        elapsed = time.monotonic() - started

        self.assertEqual(results["a"][0], 200)
        self.assertEqual(results["b"][0], 200)
        one_move = 20 * 2 * 0.005
        self.assertLess(elapsed, one_move * 1.8,
                        "two motors took %.3fs; a single move is ~%.3fs, so they "
                        "ran one after the other" % (elapsed, one_move))

    def test_stopping_one_motor_leaves_the_other_running(self):
        outcome = {}

        def drive(motor_id, steps):
            response = self.client.post(
                "/motor/%s/run" % motor_id,
                json={"steps": steps, "steptype": "Half", "stepdelay": 0.001})
            outcome[motor_id] = response.get_json()

        # 'a' is long enough to still be moving when the stop lands; 'b' is
        # short and must complete normally.
        long_run = threading.Thread(target=drive, args=("a", 4000))
        long_run.start()
        # Wait until 'a' has actually taken the lock, rather than sleeping and
        # hoping -- a fixed sleep makes this test flaky on a loaded machine.
        deadline = time.monotonic() + 5
        while not self.server.motors["a"].lock.locked():
            if time.monotonic() > deadline:
                self.fail("motor a never started")
            time.sleep(0.005)

        drive("b", 10)
        self.assertEqual(outcome["b"]["status"], "success",
                         "motor b did not complete while a was stopped")

        self.client.post("/motor/a/stop")
        long_run.join(timeout=30)
        self.assertFalse(long_run.is_alive(), "stop did not end motor a's run")
        self.assertEqual(outcome["a"]["status"], "stopped")

    def test_stop_is_not_global(self):
        self.client.post("/motor/a/stop")
        self.assertTrue(self.client.get("/motor/a/status").get_json()["stop_requested"])
        self.assertFalse(self.client.get("/motor/b/status").get_json()["stop_requested"])

    def test_busy_motor_refuses_a_second_command(self):
        def drive():
            self.client.post("/motor/a/run",
                             json={"steps": 2000, "steptype": "Half",
                                   "stepdelay": 0.001})

        first = threading.Thread(target=drive)
        first.start()
        deadline = time.monotonic() + 5
        while not self.server.motors["a"].lock.locked():
            if time.monotonic() > deadline:
                self.fail("motor a never started")
            time.sleep(0.005)

        second = self.client.post("/motor/a/run", json={"steps": 5})
        self.assertEqual(second.status_code, 409)
        self.assertEqual(second.get_json()["status"], "busy")

        self.client.post("/motor/a/stop")
        first.join(timeout=30)

    # --- back compatibility ----------------------------------------------

    def test_legacy_routes_target_the_first_motor(self):
        self.client.post("/run_motor",
                         json={"steps": 4, "steptype": "Half", "stepdelay": 0})
        stepped = {pin for pin, _ in GPIO.edges}
        self.assertIn(23, stepped)
        self.assertNotIn(6, stepped)

        self.assertEqual(self.client.get("/status").get_json(),
                         {"status": "running"})

        self.client.post("/stop_motor")
        self.assertTrue(
            self.client.get("/motor/a/status").get_json()["stop_requested"])

    # --- input handling ---------------------------------------------------

    def test_invalid_steptype_is_400_not_500(self):
        response = self.client.post("/motor/a/run",
                                    json={"steps": 1, "steptype": "1/256"})
        self.assertEqual(response.status_code, 400)
        self.assertIn("invalid steptype", response.get_json()["message"])

    def test_bad_steps_rejected(self):
        for payload in ({"steps": "many"}, {"steps": -5}):
            response = self.client.post("/motor/a/run", json=payload)
            self.assertEqual(response.status_code, 400, payload)

    def test_single_motor_configuration(self):
        """One entry must give a working single-motor server.

        In a SEPARATE interpreter on purpose. `app` is a module-level
        singleton, so a second MotorServer built in this process would try to
        register routes on an app that has already served a request and Flask
        rejects that. The instrument only ever builds one, and a subprocess is
        how the single-motor case gets tested without pretending otherwise.
        """
        script = (
            "import os, sys, types, threading\n"
            "sys.path.insert(0, %r)\n"
            "sys.path.insert(0, %r)\n"
            "from test_motor_server import install_gpio_shim\n"
            "install_gpio_shim()\n"
            "os.environ['PUMP_CACHE_TYPE'] = 'SimpleCache'\n"
            "sys.path.insert(0, %r)\n"
            "import motor_server\n"
            "s = motor_server.MotorServer(motor_specs=['only:22,23'])\n"
            "c = motor_server.app.test_client()\n"
            "b = c.get('/motors').get_json()\n"
            "assert s.order == ['only'], s.order\n"
            "assert b['default'] == 'only', b\n"
            "assert b['motors'][0]['mode_pins'] == [-1, -1, -1], b\n"
            "r = c.post('/run_motor', json={'steps': 2, 'steptype': 'Half',"
            " 'stepdelay': 0})\n"
            "assert r.status_code == 200, r.get_json()\n"
            "print('single-motor ok')\n"
        ) % (os.path.dirname(os.path.abspath(__file__)), PKG_DIR, PKG_DIR)

        import subprocess
        result = subprocess.run([sys.executable, "-c", script],
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 0,
                         "single-motor server failed:\n%s\n%s"
                         % (result.stdout, result.stderr))
        self.assertIn("single-motor ok", result.stdout)


if __name__ == "__main__":
    unittest.main(verbosity=2)
