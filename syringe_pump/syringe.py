from .curl_requests import run_motor, stop_motor, check_status
import logging
import math


# Drive hardware: fixed by the motor and lead screw, the same for every syringe.
step_angle = 1.8 # degrees per FULL step
thread_pitch = 0.8 # mm

# Microsteps per full step for each A4988 step mode. In any mode but Full, one
# STEP pulse turns the shaft step_angle / microsteps, so the same volume needs
# proportionally more pulses.
MICROSTEPS = {
    "Full": 1,
    "Half": 2,
    "1/4": 4,
    "1/8": 8,
    "1/16": 16,
}
DEFAULT_STEPTYPE = "Full"


def _microsteps(steptype):
    try:
        return MICROSTEPS[steptype]
    except KeyError:
        raise ValueError("invalid steptype: {!r} (expected one of {})".format(
            steptype, ", ".join(MICROSTEPS))) from None

# Barrel INNER radius in mm, by syringe size. Brands differ (a Terumo 10 mL is
# wider than a BD one), so check yours against the manufacturer's spec or with
# calipers before trusting a volume. Add your own entries freely.
SYRINGE_RADII = {
    "30mL": 11.0,    # the original hardcoded value
    "10mL": 7.25,    # BD Luer-Lok, 14.5 mm inner diameter
}
DEFAULT_SYRINGE_RADIUS = SYRINGE_RADII["30mL"]

# Kept for anything that imported the old module-level constants.
syringe_radius = DEFAULT_SYRINGE_RADIUS


def vol_per_step(radius=DEFAULT_SYRINGE_RADIUS, steptype=DEFAULT_STEPTYPE):
    """Volume moved by one STEP pulse, in uL (= mm^3).

    Args:
        radius (float): Barrel inner radius in mm.
        steptype (str): The step mode the move runs in, e.g. "Full" or "Half".
    """
    degrees_per_pulse = step_angle / _microsteps(steptype)
    return math.pi * radius**2 * thread_pitch * degrees_per_pulse / 360


def vol_to_steps(vol, radius=DEFAULT_SYRINGE_RADIUS, steptype=DEFAULT_STEPTYPE):
    """Convert a volume in uL to STEP pulses for a barrel radius and step mode."""
    return int(vol / vol_per_step(radius, steptype))

direction_mapping = {'aspirate':'counter-clockwise', 'dispense':'clockwise'}



class SyringePump:
    """A class to control syringe pump operations."""

    def __init__(self, url = "http://10.194.22.184:5000", simulating = False, motor = None, rinse_pump_array = None, rinse_pump_number = None, drain_pump_number = None, syringe_radius = DEFAULT_SYRINGE_RADIUS, steptype = DEFAULT_STEPTYPE):
        """
        Initialize the SyringePump.

        Args:
            ip_address (str): The IP address of the pump server
            rinse_pump_array: The pump array for rinsing operations
            motor (str): Which motor on the server drives this syringe,
                e.g. "a" or "b". Leave as None for a single-motor server.
            rinse_pump_number (int): The pump number for rinse operations
            drain_pump_number (int): The pump number for drain operations
            syringe_radius (float): Inner radius of the syringe barrel in mm.
                Defaults to the 30 mL syringe; use SYRINGE_RADII["10mL"] etc.
                for others.
            steptype (str): Step mode for moves: "Full", "Half", "1/4", "1/8"
                or "1/16". Volumes are converted to steps for this mode. If the
                driver's MS1-MS3 are strapped in hardware rather than wired to
                the Pi, this MUST match the strapping, since the server cannot
                change it.
        """
        if not syringe_radius > 0:
            raise ValueError(f"syringe_radius must be positive, got {syringe_radius!r}")
        _microsteps(steptype)  # fail now, not on the first move
        self.url = url
        self.simulating = simulating
        self.motor = motor
        self.syringe_radius = syringe_radius
        self.steptype = steptype
        self.rinse_pump_array = rinse_pump_array
        self.rinse_pump_number = rinse_pump_number
        self.drain_pump_number = drain_pump_number

    def _move(self, vol, direction, steptype):
        # Steps and steptype come from the same value, so the count sent is
        # always the one computed for the mode the driver is put in.
        steptype = steptype or self.steptype
        steps = vol_to_steps(vol, self.syringe_radius, steptype)
        return run_motor(steps=steps, url=self.url, motor=self.motor,
                         direction=direction, steptype=steptype, stepdelay=0.0001)

    def aspirate_vol(self, vol, steptype=None):
        """
        Load a specific volume into the syringe.

        Args:
            vol (float): The volume to load, in uL
            steptype (str): Override this pump's step mode for this move only
        """
        logging.info(f"Loading {vol} uL into syringe pump.")
        if self.simulating:
            return
        return self._move(vol, "counter-clockwise", steptype)

    def dispense_vol(self, vol, steptype=None):
        """
        Dispense a specific volume from the syringe.

        Args:
            vol (float): The volume to dispense, in uL
            steptype (str): Override this pump's step mode for this move only
        """
        logging.info(f"Dispensing {vol} uL from syringe pump.")
        if self.simulating:
            return
        return self._move(vol, "clockwise", steptype)


    def rinse_trough(self, vol):
        """
        Rinse the trough with a specific volume.

        Args:
            vol (float): The volume to use for rinsing
        
        Raises:
            ValueError: If the washer pump is not initialized
        """
        logging.info(f"Rinsing trough with {vol} uL.")
        if not self.rinse_pump_array:
            raise ValueError("Rinse pump array not initialized.")
        self.rinse_pump_array.pump_by_number(self.rinse_pump_number, vol, 'high')
        self.rinse_pump_array.pump_by_number(self.drain_pump_number, vol + 10, 'high')

    def check_status(self):
        """Check the status of this pump's motor."""
        return check_status(url=self.url, motor=self.motor)

    def stop(self):
        """Stop this pump's motor mid-move."""
        logging.info("Stopping syringe pump.")
        if self.simulating:
            return
        return stop_motor(url=self.url, motor=self.motor)
