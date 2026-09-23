import RPi.GPIO as GPIO
from time import sleep
import sys
import time

bool_to_string = {True:'True', False: 'False'}
string_to_bool = {'True':True, 'False': False, None: None}


def _truthy(value):
    """Interpret a stop flag read back from the cache.

    Indexing string_to_bool directly raised KeyError on anything it did not
    list -- a stale value, or the bytes a raw Redis client returns -- and the
    broad `except Exception` in motor_go swallowed it, so the motor stopped
    mid-run and reported success. Anything unrecognised means "not stopped".
    """
    if isinstance(value, bytes):
        value = value.decode("utf-8", "replace")
    if isinstance(value, str):
        return value.strip().lower() in ("true", "1", "yes")
    return bool(value)


class StopMotorInterrupt(Exception):
    """ Stop the motor """
    pass

class A4988Nema(object):
    """ Class to control a Nema bi-polar stepper motor with a A4988 also tested with DRV8825"""
    def __init__(self, direction_pin, step_pin, mode_pins, cache = None, motor_type="A4988",
                 stop_key="stop_motor", stop_poll=32):
        """ class init method 3 inputs
        (1) direction type=int , help=GPIO pin connected to DIR pin of IC
        (2) step_pin type=int , help=GPIO pin connected to STEP of IC
        (3) mode_pins type=tuple of 3 ints, help=GPIO pins connected to
        Microstep Resolution pins MS1-MS3 of IC, can be set to (-1,-1,-1) to turn off
        GPIO resolution.
        (4) motor_type type=string, help=Type of motor two options: A4988 or DRV8825
        (5) stop_key type=string, help=cache key this motor watches for a stop
        request. Each motor needs its own, or stopping one stops them all.
        (6) stop_poll type=int, help=check the stop key every N steps.
        """
        self.motor_type = motor_type
        self.direction_pin = direction_pin
        self.step_pin = step_pin
        self.cache = cache
        # The key was hardcoded to 'motor_stop' while the server wrote
        # 'stop_motor', so a stop request was never seen. Making it a
        # parameter fixes that and gives each motor its own flag.
        self.stop_key = stop_key
        self.stop_poll = max(1, int(stop_poll))

        if mode_pins[0] != -1:
            self.mode_pins = mode_pins
        else:
            self.mode_pins = False

        self.stop_motor = False
        GPIO.setmode(GPIO.BCM)
        GPIO.setwarnings(False)

    def motor_stop(self):
        """ Stop the motor """
        self.stop_motor = True

    def resolution_set(self, steptype):
        """ method to calculate step resolution
        based on motor type and steptype"""
        if self.motor_type == "A4988":
            resolution = {'Full': (0, 0, 0),
                          'Half': (1, 0, 0),
                          '1/4': (0, 1, 0),
                          '1/8': (1, 1, 0),
                          '1/16': (1, 1, 1)}
        elif self.motor_type == "DRV8825":
            resolution = {'Full': (0, 0, 0),
                          'Half': (1, 0, 0),
                          '1/4': (0, 1, 0),
                          '1/8': (1, 1, 0),
                          '1/16': (0, 0, 1),
                          '1/32': (1, 0, 1)}
        elif self.motor_type == "LV8729":
            resolution = {'Full': (0, 0, 0),
                          'Half': (1, 0, 0),
                          '1/4': (0, 1, 0),
                          '1/8': (1, 1, 0),
                          '1/16': (0, 0, 1),
                          '1/32': (1, 0, 1),
                          '1/64': (0, 1, 1),
                          '1/128': (1, 1, 1)}
        else:
            # quit() raises SystemExit. Inside a Flask request thread that
            # tears down the server over one bad request, so a caller's typo
            # took the whole instrument offline. Raise instead and let the
            # route turn it into a 400.
            raise ValueError("invalid motor_type: {}".format(self.motor_type))

        # error check stepmode
        if steptype not in resolution:
            raise ValueError("invalid steptype: {} (expected one of {})".format(
                steptype, ", ".join(sorted(resolution))))

        if self.mode_pins != False:
            GPIO.output(self.mode_pins, resolution[steptype])

    def motor_go(self, clockwise=False, steptype="Full",
                 steps=200, stepdelay=.005, verbose=False, initdelay=.05):
        """ motor_go,  moves stepper motor based on 6 inputs

         (1) clockwise, type=bool default=False
         help="Turn stepper counterclockwise"
         (2) steptype, type=string , default=Full help= type of drive to
         step motor 5 options
            (Full, Half, 1/4, 1/8, 1/16) 1/32 for DRV8825 only 1/64 1/128 for LV8729 only
         (3) steps, type=int, default=200, help=Number of steps sequence's
         to execute. Default is one revolution , 200 in Full mode.
         (4) stepdelay, type=float, default=0.05, help=Time to wait
         (in seconds) between steps.
         (5) verbose, type=bool  type=bool default=False
         help="Write pin actions",
         (6) initdelay, type=float, default=1mS, help= Intial delay after
         GPIO pins initialized but before motor is moved.

        """
        self.stop_motor = False
        # setup GPIO
        GPIO.setup(self.direction_pin, GPIO.OUT)
        GPIO.setup(self.step_pin, GPIO.OUT)
        GPIO.output(self.direction_pin, clockwise)
        if self.mode_pins != False:
            GPIO.setup(self.mode_pins, GPIO.OUT)
        # Outside the try on purpose: an invalid steptype or motor_type is a
        # caller error, and the broad `except Exception` below would swallow it
        # and let the route report a move that never happened.
        self.resolution_set(steptype)

        try:
            time.sleep(initdelay)

            for i in range(steps):
                # Polling the cache on EVERY step meant a Redis round trip per
                # step. At stepdelay=0.0001 the round trip dominates the step
                # period, so the motor ran at the network's pace rather than
                # the one asked for -- and with two motors stepping at once,
                # each one's latency became the other's jitter. Checking every
                # stop_poll steps keeps stop responsive (32 steps is well under
                # a millisecond of travel) at a fraction of the traffic.
                if self.cache and i % self.stop_poll == 0:
                    if _truthy(self.cache.get(self.stop_key)):
                        raise StopMotorInterrupt

                GPIO.output(self.step_pin, True)
                time.sleep(stepdelay)
                GPIO.output(self.step_pin, False)
                time.sleep(stepdelay)
                # Unconditional in this fork, so a 20000-step run wrote 20000
                # lines to the journal and the I/O showed up as step jitter.
                # Back behind the flag the parameter already exists for.
                if verbose:
                    print("Steps count {}".format(i+1), end="\r", flush=True)

        except KeyboardInterrupt:
            print("User Keyboard Interrupt : RpiMotorLib:")
        except StopMotorInterrupt:
            print("Stop Motor Interrupt : RpiMotorLib: ")
        except Exception as motor_error:
            print(sys.exc_info()[0])
            print(motor_error)
            print("RpiMotorLib  : Unexpected error:")
        finally:
            # cleanup
            GPIO.output(self.step_pin, False)
            GPIO.output(self.direction_pin, False)
            if self.mode_pins != False:
                for pin in self.mode_pins:
                    GPIO.output(pin, False)
