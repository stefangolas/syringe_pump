from .curl_requests import run_motor, stop_motor, check_status
import logging


# Constants
syringe_radius = 11 # mm
step_angle = 1.8 # degrees
thread_pitch = 0.8 # mm
vol_per_step = 3.14159 * syringe_radius**2 * thread_pitch * step_angle / 360 # mm^3 or uL
steps_per_vol = 1 / vol_per_step

def vol_to_steps(vol):
    """Convert volume to motor steps."""
    return int(vol * steps_per_vol)

direction_mapping = {'aspirate':'counter-clockwise', 'dispense':'clockwise'}



class SyringePump:
    """A class to control syringe pump operations."""

    def __init__(self, url = "http://10.194.22.184:5000", simulating = False, motor = None, rinse_pump_array = None, rinse_pump_number = None, drain_pump_number = None):
        """
        Initialize the SyringePump.

        Args:
            ip_address (str): The IP address of the pump server
            rinse_pump_array: The pump array for rinsing operations
            motor (str): Which motor on the server drives this syringe,
                e.g. "a" or "b". Leave as None for a single-motor server.
            rinse_pump_number (int): The pump number for rinse operations
            drain_pump_number (int): The pump number for drain operations
        """
        self.url = url
        self.simulating = simulating
        self.motor = motor
        self.rinse_pump_array = rinse_pump_array
        self.rinse_pump_number = rinse_pump_number
        self.drain_pump_number = drain_pump_number

    def aspirate_vol(self, vol):
        """
        Load a specific volume into the syringe.

        Args:
            vol (float): The volume to load
        """
        logging.info(f"Loading {vol} uL into syringe pump.")
        if self.simulating:
            return
        steps = vol_to_steps(vol)
        run_motor(steps=steps, url=self.url, motor=self.motor,
                  direction="counter-clockwise", steptype="Half", stepdelay=0.0001)
    
    def dispense_vol(self, vol):
        logging.info(f"Dispensing {vol} uL from syringe pump.")
        if self.simulating:
            return
        steps = vol_to_steps(vol)
        run_motor(steps=steps, url=self.url, motor=self.motor,
                  direction="clockwise", steptype="Half", stepdelay=0.0001)


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
