import requests
from typing import Optional, Dict, Any

DEFAULT_URL = "http://10.194.22.184:5000"


def _endpoint(url: str, motor: Optional[str], action: str) -> str:
    """Build the URL for an action, on a named motor or on the default one.

    With no motor the original single-motor routes are used, so a server that
    predates multi-motor support still answers.
    """
    if motor is None:
        return "{}/{}".format(url.rstrip("/"), action)
    return "{}/motor/{}/{}".format(url.rstrip("/"), motor,
                                   "run" if action == "run_motor" else "stop")


def run_motor(steps: int = 200, url: str = DEFAULT_URL,
              direction: str = "counter-clockwise", steptype="1/8",
              stepdelay=0.0005, motor: Optional[str] = None,
              timeout: Optional[float] = None) -> Optional[Dict[str, Any]]:
    """
    Run a motor with specified parameters.

    Args:
        steps (int): Number of steps to run the motor
        url (str): The base URL for the motor control server
        direction (str): Direction to run ("counter-clockwise" or "clockwise")
        steptype (str): Microstep mode, e.g. "Full", "Half", "1/8"
        stepdelay (float): Seconds between step edges
        motor (str): Which motor to command, e.g. "a" or "b". None targets the
            server's default (first) motor via the legacy route.
        timeout (float): Seconds to wait. A long move holds the response open
            for its whole duration, so leave this as None unless you know the
            move is short.

    Returns:
        Optional[Dict[str, Any]]: The JSON response, or None on error
    """
    if url is None:
        raise ValueError("URL must be provided")

    data = {
        "steps": steps,
        "direction": direction,
        "steptype": steptype,
        "stepdelay": stepdelay,
    }
    try:
        response = requests.post(_endpoint(url, motor, "run_motor"),
                                 json=data, timeout=timeout)
        response.raise_for_status()
        return response.json()
    except requests.RequestException as e:
        print(f"An error occurred while running the motor: {e}")
        return None


def stop_motor(url: str = DEFAULT_URL, motor: Optional[str] = None,
               timeout: Optional[float] = 5) -> Optional[Dict[str, Any]]:
    """
    Ask a motor to stop. Returns as soon as the flag is set; the in-flight
    run_motor call returns separately, with status "stopped".

    Args:
        url (str): The base URL for the motor control server
        motor (str): Which motor to stop. None targets the default motor.
    """
    if url is None:
        raise ValueError("URL must be provided")
    try:
        response = requests.post(_endpoint(url, motor, "stop_motor"),
                                 timeout=timeout)
        response.raise_for_status()
        return response.json()
    except requests.RequestException as e:
        print(f"An error occurred while stopping the motor: {e}")
        return None


def check_status(url: Optional[str] = None, motor: Optional[str] = None,
                 timeout: Optional[float] = 5) -> Optional[Dict[str, Any]]:
    """
    Check the status of the server, or of one motor.

    Args:
        url (str): The base URL for the motor control server
        motor (str): Report on this motor specifically -- whether it is moving
            and whether a stop is pending. None reports on the server.

    Returns:
        Optional[Dict[str, Any]]: The JSON response, or None on error
    """
    if url is None:
        raise ValueError("URL must be provided")

    if motor is None:
        endpoint = "{}/status".format(url.rstrip("/"))
    else:
        endpoint = "{}/motor/{}/status".format(url.rstrip("/"), motor)
    try:
        response = requests.get(endpoint, timeout=timeout)
        response.raise_for_status()
        return response.json()
    except requests.RequestException as e:
        print(f"An error occurred while checking the status: {e}")
        return None


def list_motors(url: str = DEFAULT_URL,
                timeout: Optional[float] = 5) -> Optional[Dict[str, Any]]:
    """List the motors the server was started with, and their pins."""
    try:
        response = requests.get("{}/motors".format(url.rstrip("/")),
                                timeout=timeout)
        response.raise_for_status()
        return response.json()
    except requests.RequestException as e:
        print(f"An error occurred while listing motors: {e}")
        return None


if __name__ == '__main__':
    url = DEFAULT_URL
    print(list_motors(url=url))
    run_motor(steps=20000, url=url, direction="clockwise", motor="a")
    status = check_status(url=url, motor="a")
    if status:
        print(f"Motor status: {status}")
