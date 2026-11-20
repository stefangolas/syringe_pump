from .curl_requests import run_motor, stop_motor, check_status
from .errors import SyringePumpError, PumpTimeoutError
import logging
import math

log = logging.getLogger(__name__)


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

# Seconds the STEP pin is held high, and then low, per step: one step takes
# 2 x stepdelay, so 0.0005 is 1000 full steps/s. Chosen on the instrument:
# motor c with a syringe fitted runs smoothly in Full at this speed. (The old
# hardcoded 0.0001 was below the point where the server's per-step overhead,
# not the delay, sets the real speed.)
DEFAULT_STEPDELAY = 0.0005


def _check_stepdelay(stepdelay):
    if not (isinstance(stepdelay, (int, float)) and stepdelay > 0):
        raise ValueError(f"stepdelay must be a positive number of seconds, got {stepdelay!r}")
    return stepdelay


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
    "30mL": 10.75,    # the original hardcoded value
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


def default_move_timeout(steps, stepdelay):
    """Client-side timeout for a move, in seconds.

    The server holds the HTTP reply open until the move ends, so the timeout
    must outlast the move itself: one step takes 2 x stepdelay, plus 50% for
    the server's per-step overhead, plus 10 s for connecting and settling.

        timeout = steps * 2 * stepdelay * 1.5 + 10

    e.g. 15 000 steps at 0.0005 -> 32.5 s.
    """
    return steps * 2 * stepdelay * 1.5 + 10

direction_mapping = {'aspirate':'counter-clockwise', 'dispense':'clockwise'}



class SyringePump:
    """A class to control syringe pump operations."""

    def __init__(self, url = "http://10.194.22.184:5000", simulating = False, motor = None, rinse_pump_array = None, rinse_pump_number = None, drain_pump_number = None, syringe_radius = DEFAULT_SYRINGE_RADIUS, steptype = DEFAULT_STEPTYPE, stepdelay = DEFAULT_STEPDELAY, strict = True, move_timeout_s = None, name = ""):
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
            stepdelay (float): Seconds high, then low, per step pulse, so one
                step takes 2 x stepdelay. Larger is slower. In Full mode a
                motor can resonate and skip steps in a narrow speed band
                (motor c: around 0.005); avoid it or use a finer steptype.
            strict (bool): True (default) makes aspirate_vol / dispense_vol
                raise a SyringePumpError subclass whenever a move does not
                fully complete. False restores the old behaviour: return
                whatever run_motor returns, None on failure.
            move_timeout_s (float): Seconds to wait for a move's reply. None
                (default) sizes it to each move; see default_move_timeout.
            name (str): A label for log lines and error messages, e.g. "ctb".
        """
        if not syringe_radius > 0:
            raise ValueError(f"syringe_radius must be positive, got {syringe_radius!r}")
        _check_stepdelay(stepdelay)
        _microsteps(steptype)  # fail now, not on the first move
        self.url = url
        self.simulating = simulating
        self.motor = motor
        self.syringe_radius = syringe_radius
        self.steptype = steptype
        self.stepdelay = stepdelay
        self.strict = strict
        self.move_timeout_s = move_timeout_s
        self.name = name
        self.rinse_pump_array = rinse_pump_array
        self.rinse_pump_number = rinse_pump_number
        self.drain_pump_number = drain_pump_number

    def _where(self):
        where = f"motor {self.motor!r} @ {self.url}"
        return f"syringe {self.name!r} ({where})" if self.name else where

    def _move(self, vol, direction, steptype, stepdelay, move_timeout_s=None):
        # Steps and steptype come from the same value, so the count sent is
        # always the one computed for the mode the driver is put in.
        steptype = steptype or self.steptype
        stepdelay = self.stepdelay if stepdelay is None else _check_stepdelay(stepdelay)
        steps = vol_to_steps(vol, self.syringe_radius, steptype)
        if move_timeout_s is None:
            move_timeout_s = self.move_timeout_s
        action = "{} {} uL".format(
            "Dispensing" if direction == "clockwise" else "Aspirating", vol)
        log.info("%s on %s (%d steps, %s, stepdelay %s).",
                 action, self._where(), steps, steptype, stepdelay)

        if self.simulating:
            return {"status": "success", "simulated": True}

        if not self.strict:
            # The old behaviour: no timeout unless one was asked for, and
            # whatever run_motor returns, None on failure.
            return run_motor(steps=steps, url=self.url, motor=self.motor,
                             direction=direction, steptype=steptype,
                             stepdelay=stepdelay, timeout=move_timeout_s)

        if move_timeout_s is None:
            move_timeout_s = default_move_timeout(steps, stepdelay)
        try:
            return run_motor(steps=steps, url=self.url, motor=self.motor,
                             direction=direction, steptype=steptype,
                             stepdelay=stepdelay, timeout=move_timeout_s,
                             raise_on_error=True)
        except PumpTimeoutError as e:
            # The server is probably still driving the motor. Stop it, but
            # never let a failure here hide the timeout itself.
            try:
                status = check_status(url=self.url, motor=self.motor)
                if status and status.get("busy"):
                    e.stop_sent = stop_motor(url=self.url, motor=self.motor) is not None
            except Exception:
                log.exception("Cleanup after a timed-out move on %s failed.", self._where())
            self._annotate(e, action, steptype)
            raise
        except SyringePumpError as e:
            self._annotate(e, action, steptype)
            raise

    def _annotate(self, e, action, steptype):
        e.name = self.name
        e.action = action
        if e.steps_completed is not None:
            e.volume_completed_ul = e.steps_completed * vol_per_step(
                self.syringe_radius, steptype)
        log.error("%s", e)

    def aspirate_vol(self, vol, steptype=None, stepdelay=None, move_timeout_s=None):
        """
        Load a specific volume into the syringe.

        Args:
            vol (float): The volume to load, in uL
            steptype (str): Override this pump's step mode for this move only
            stepdelay (float): Override this pump's step delay for this move only
            move_timeout_s (float): Override this pump's move timeout for this move only

        Returns:
            The server's reply dict ({"status": "success", "simulated": True}
            when simulating).

        Raises:
            SyringePumpError: (strict pumps) the move did not fully complete.
        """
        return self._move(vol, "counter-clockwise", steptype, stepdelay, move_timeout_s)

    def dispense_vol(self, vol, steptype=None, stepdelay=None, move_timeout_s=None):
        """
        Dispense a specific volume from the syringe.

        Args:
            vol (float): The volume to dispense, in uL
            steptype (str): Override this pump's step mode for this move only
            stepdelay (float): Override this pump's step delay for this move only
            move_timeout_s (float): Override this pump's move timeout for this move only

        Returns:
            The server's reply dict ({"status": "success", "simulated": True}
            when simulating).

        Raises:
            SyringePumpError: (strict pumps) the move did not fully complete.
        """
        return self._move(vol, "clockwise", steptype, stepdelay, move_timeout_s)


    def rinse_trough(self, vol):
        """
        Rinse the trough with a specific volume.

        Args:
            vol (float): The volume to use for rinsing
        
        Raises:
            ValueError: If the washer pump is not initialized
        """
        log.info(f"Rinsing trough with {vol} uL.")
        if not self.rinse_pump_array:
            raise ValueError("Rinse pump array not initialized.")
        self.rinse_pump_array.pump_by_number(self.rinse_pump_number, vol, 'high')
        self.rinse_pump_array.pump_by_number(self.drain_pump_number, vol + 10, 'high')

    def check_status(self):
        """Check the status of this pump's motor."""
        return check_status(url=self.url, motor=self.motor)

    def stop(self):
        """Stop this pump's motor mid-move."""
        log.info("Stopping %s.", self._where())
        if self.simulating:
            return
        return stop_motor(url=self.url, motor=self.motor)
