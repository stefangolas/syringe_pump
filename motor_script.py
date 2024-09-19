from flask import Flask, request, jsonify
import RPi.GPIO as GPIO
from A4988 import A4988Nema

app = Flask(__name__)

# Set up GPIO pins
DIR_PIN = 20  # Direction GPIO Pin
STEP_PIN = 21  # Step GPIO Pin
MODE_PINS = (14, 15, 18)  # Microstep Resolution GPIO Pins

# Create an instance of the A4988Nema class
motor = A4988Nema(DIR_PIN, STEP_PIN, MODE_PINS)

@app.route('/run_motor', methods=['POST'])
def run_motor():
    data = request.json
    steps = data.get('steps', 200)  # Default to 200 steps if not provided
    direction = data.get('direction', 'clockwise')  # Default to clockwise if not provided
    
    clockwise = direction.lower() == 'clockwise'
    
    try:
        motor.motor_go(clockwise=clockwise, steptype="Full", steps=steps, stepdelay=0.005)
        return jsonify({"status": "success", "message": f"Motor ran {steps} steps in {'clockwise' if clockwise else 'counter-clockwise'} direction"}), 200
    except Exception as e:
        return jsonify({"status": "error", "message": str(e)}), 500

@app.route('/status', methods=['GET'])
def status():
    return jsonify({"status": "running"}), 200

if __name__ == '__main__':
    try:
        app.run(host='0.0.0.0', port=5000)
    finally:
        GPIO.cleanup()