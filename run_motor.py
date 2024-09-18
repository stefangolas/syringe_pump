import RPi.GPIO as GPIO
from time import sleep
from A4988 import A4988Nema
import sys

DIR_PIN = 22  # Direction GPIO Pin
STEP_PIN = 23  # Step GPIO Pin
MODE_PINS = (17, 27, 25)  # Microstep Resolution GPIO Pins

motor = A4988Nema(DIR_PIN, STEP_PIN, MODE_PINS)
# Set up GPIO pins
EN_pin = 24
GPIO.setup(EN_pin,GPIO.OUT)
#GPIO.setmode(GPIO.BOARD)
#GPIO.setup(EN_pin,GPIO.OUT)



# Create an instance of the A4988Nema class


try:
    print("Running motor...")
    GPIO.output(EN_pin,GPIO.LOW)
    # Run the motor: 200 steps (1 revolution for a 1.8-degree stepper) clockwise
    motor.motor_go(clockwise=True, steptype="1/16", steps=200, stepdelay=0.05, verbose=True)
    sleep(1)  # Wait for 1 second
    
    print("Reversing motor direction...")
    # Run the motor: 200 steps counter-clockwise
    motor.motor_go(clockwise=False, steptype="1/16", steps=200, stepdelay=0.005)
    GPIO.output(EN_pin,GPIO.HIGH)
    print("Motor sequence completed.")

except KeyboardInterrupt:
    print("Motor stopped by user")

finally:
    print("Cleaning up GPIO")
    GPIO.cleanup()