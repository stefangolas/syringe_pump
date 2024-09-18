import RPi.GPIO as GPIO
from time import sleep
from A4988 import A4988Nema

# Set up GPIO pins
DIR_PIN = 20  # Direction GPIO Pin
STEP_PIN = 21  # Step GPIO Pin
MODE_PINS = (14, 15, 18)  # Microstep Resolution GPIO Pins

# Create an instance of the A4988Nema class
motor = A4988Nema(DIR_PIN, STEP_PIN, MODE_PINS)

try:
    print("Running motor...")
    # Run the motor: 200 steps (1 revolution for a 1.8-degree stepper) clockwise
    motor.motor_go(clockwise=True, steptype="Full", steps=200, stepdelay=0.005)
    sleep(1)  # Wait for 1 second
    
    print("Reversing motor direction...")
    # Run the motor: 200 steps counter-clockwise
    motor.motor_go(clockwise=False, steptype="Full", steps=200, stepdelay=0.005)
    
    print("Motor sequence completed.")

except KeyboardInterrupt:
    print("Motor stopped by user")

finally:
    print("Cleaning up GPIO")
    GPIO.cleanup()