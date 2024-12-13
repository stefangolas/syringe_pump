from flask import Flask, request, jsonify
import RPi.GPIO as GPIO
from A4988 import A4988Nema
import argparse
from flask_caching import Cache



app = Flask(__name__)
app.config['CACHE_TYPE'] = 'RedisCache' 
cache = Cache(app)


class MotorServer:
    def __init__(self, dir_pin=20, step_pin=21, mode_pins=(14, 15, 18), cache=cache):
        self.dir_pin = dir_pin
        self.step_pin = step_pin
        self.mode_pins = mode_pins
        self.motor = A4988Nema(dir_pin, step_pin, mode_pins, cache)
        self.setup_routes()

    def setup_routes(self):
        @app.route('/run_motor', methods=['POST'])
        def run_motor():
            data = request.json
            steps = data.get('steps', 200)
            direction = data.get('direction', 'clockwise')
            steptype = data.get('steptype', '1/8')
            stepdelay = data.get('stepdelay', 0.0005)
            
            clockwise = direction.lower() == 'clockwise'
            
            try:
                self.cache.set('stop_motor', 'False')
                self.motor.motor_go(clockwise=clockwise, steptype=steptype, steps=steps, stepdelay=stepdelay)
                print(f"Motor ran {steps} steps in {'clockwise' if clockwise else 'counter-clockwise'} direction")
                return jsonify({
                    "status": "success", 
                    "message": f"Motor ran {steps} steps in {'clockwise' if clockwise else 'counter-clockwise'} direction"
                }), 200
            except Exception as e:
                return jsonify({"status": "error", "message": str(e)}), 500
        
        @app.route('/status', methods=['GET'])
        def status():
            return jsonify({"status": "running"}), 200
        
        @app.route('/stop_motor', methods=['POST'])
        def stop_motor():
            self.cache.set('stop_motor', 'True')
            return jsonify({"status": "success", "message": "Motor stopped"}), 200

    def run(self, host='0.0.0.0', port=5000):
        try:
            app.run(host=host, port=port)
        finally:
            GPIO.cleanup()

def main():
    parser = argparse.ArgumentParser(description='Run the syringe pump motor server')
    parser.add_argument('--host', default='0.0.0.0', help='Host to run the server on')
    parser.add_argument('--port', type=int, default=5000, help='Port to run the server on')
    parser.add_argument('--dir-pin', type=int, default=20, help='GPIO pin for direction control')
    parser.add_argument('--step-pin', type=int, default=21, help='GPIO pin for step control')
    parser.add_argument('--mode-pins', type=int, nargs=3, default=[14, 15, 18], 
                      help='GPIO pins for microstep resolution (3 pins)')
    
    args = parser.parse_args()
    
    server = MotorServer(
        dir_pin=args.dir_pin,
        step_pin=args.step_pin,
        mode_pins=tuple(args.mode_pins)
    )
    
    print(f"Starting motor server on {args.host}:{args.port}")
    server.run(host=args.host, port=args.port)

if __name__ == '__main__':
    main()
