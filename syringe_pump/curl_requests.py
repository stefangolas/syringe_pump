import requests
import json
from typing import Optional, Dict, Any

def run_motor(steps: int = 200, url: str = None, direction: str = "counter-clockwise") -> Optional[Dict[str, Any]]:
    """
    Run the motor with specified parameters.

    Args:
        steps (int): Number of steps to run the motor
        url (str): The base URL for the motor control server
        direction (str): Direction to run the motor ("counter-clockwise" or "clockwise")

    Returns:
        Optional[Dict[str, Any]]: The JSON response from the server, or None if an error occurred
    """
    if url is None:
        raise ValueError("URL must be provided")

    endpoint = f"{url}/run_motor"
    data = {
        "steps": steps,
        "direction": direction,
        "steptype": "1/8",

    }
    try:
        response = requests.post(endpoint, json=data)
        response.raise_for_status()
        return response.json()
    except requests.RequestException as e:
        print(f"An error occurred while running the motor: {e}")
        return None

def check_status(url: str = None) -> Optional[Dict[str, Any]]:
    """
    Check the status of the motor.

    Args:
        url (str): The base URL for the motor control server

    Returns:
        Optional[Dict[str, Any]]: The JSON response from the server, or None if an error occurred
    """
    if url is None:
        raise ValueError("URL must be provided")

    endpoint = f"{url}/status"
    try:
        response = requests.get(endpoint)
        response.raise_for_status()
        return response.json()
    except requests.RequestException as e:
        print(f"An error occurred while checking the status: {e}")
        return None

if __name__=='__main__':
    url = "http://10.194.22.184:5000"
    #import IPython
    #IPython.embed()
    run_motor(steps=2000, url=url, direction="clockwise")
    status = check_status(url=url)
    if status:
        print(f"Motor status: {status}")