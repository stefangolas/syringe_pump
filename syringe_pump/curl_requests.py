import logging
import requests
from typing import Optional, Dict, Any

from .errors import (SyringePumpError, PumpUnreachableError, PumpBusyError,
                     PumpRejectedError, PumpTimeoutError, PartialMoveError)

log = logging.getLogger(__name__)

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


def _send(send, endpoint, *, what, url, motor, raise_on_error, steps=None,
          **kwargs):
    """Make one request and return its JSON reply.

    raise_on_error=False keeps the original behaviour: log the problem and
    return None. raise_on_error=True raises a SyringePumpError subclass. The
    JSON body is read BEFORE the status code is checked, so the server's own
    message (e.g. why a 409 or 400 happened) ends up in the exception.

    `send` is requests.post or requests.get, looked up at call time so tests
    can patch them.
    """
    context = dict(motor=motor, url=url, steps_requested=steps)
    try:
        response = send(endpoint, **kwargs)
    # ConnectTimeout is both a ConnectionError and a Timeout. Nothing was
    # delivered, so it is "unreachable", not "the move may still be running".
    except requests.ConnectTimeout as e:
        err = PumpUnreachableError("could not connect ({})".format(e), **context)
    except requests.Timeout as e:
        err = PumpTimeoutError(
            "no reply within {} s; the motor may still be moving ({})".format(
                kwargs.get("timeout"), e), **context)
    except requests.ConnectionError as e:
        err = PumpUnreachableError("could not reach the server ({})".format(e), **context)
    except requests.RequestException as e:
        err = SyringePumpError("request failed ({})".format(e), **context)
    else:
        try:
            body = response.json()
        except ValueError:
            body = None
        message = body.get("message") if isinstance(body, dict) else None
        code = response.status_code

        if code == 409:
            # Refused before moving: this move took no steps.
            err = PumpBusyError(message or "motor is busy (HTTP 409)", reply=body,
                                steps_completed=0 if steps is not None else None,
                                motor=motor, url=url, steps_requested=steps)
        elif not 200 <= code < 300:
            completed = body.get("steps_completed") if isinstance(body, dict) else None
            if completed is None and code in (400, 404) and steps is not None:
                completed = 0           # rejected before any step was taken
            err = PumpRejectedError("HTTP {}: {}".format(code, message or response.reason),
                                    reply=body, steps_completed=completed,
                                    motor=motor, url=url, steps_requested=steps)
        elif not isinstance(body, dict):
            err = SyringePumpError("HTTP {} with a reply that is not JSON".format(code),
                                   **context)
        else:
            return body

    if raise_on_error:
        raise err
    log.error("Error while %s: %s", what, err)
    return None


def run_motor(steps: int = 200, url: str = DEFAULT_URL,
              direction: str = "counter-clockwise", steptype="1/8",
              stepdelay=0.0005, motor: Optional[str] = None,
              timeout: Optional[float] = None,
              raise_on_error: bool = False) -> Optional[Dict[str, Any]]:
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
        raise_on_error (bool): False (default) logs a failure and returns None.
            True raises a SyringePumpError subclass instead, including
            PartialMoveError for a move the server reports as stopped.

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
    reply = _send(requests.post, _endpoint(url, motor, "run_motor"),
                  json=data, timeout=timeout, what="running the motor",
                  url=url, motor=motor, steps=steps,
                  raise_on_error=raise_on_error)
    # In raise mode _send never returns None; the check keeps type checkers happy.
    if raise_on_error and reply is not None and reply.get("status") != "success":
        raise PartialMoveError(
            "move ended with status {!r}: {}".format(reply.get("status"),
                                                     reply.get("message")),
            reply=reply, motor=motor, url=url, steps_requested=steps,
            steps_completed=reply.get("steps_completed"))
    return reply


def stop_motor(url: str = DEFAULT_URL, motor: Optional[str] = None,
               timeout: Optional[float] = 5,
               raise_on_error: bool = False) -> Optional[Dict[str, Any]]:
    """
    Ask a motor to stop. Returns as soon as the flag is set; the in-flight
    run_motor call returns separately, with status "stopped".

    Args:
        url (str): The base URL for the motor control server
        motor (str): Which motor to stop. None targets the default motor.
        raise_on_error (bool): Raise a SyringePumpError instead of returning None.
    """
    if url is None:
        raise ValueError("URL must be provided")
    return _send(requests.post, _endpoint(url, motor, "stop_motor"),
                 timeout=timeout, what="stopping the motor", url=url,
                 motor=motor, raise_on_error=raise_on_error)


def check_status(url: Optional[str] = None, motor: Optional[str] = None,
                 timeout: Optional[float] = 5,
                 raise_on_error: bool = False) -> Optional[Dict[str, Any]]:
    """
    Check the status of the server, or of one motor.

    Args:
        url (str): The base URL for the motor control server
        motor (str): Report on this motor specifically -- whether it is moving
            and whether a stop is pending. None reports on the server.
        raise_on_error (bool): Raise a SyringePumpError instead of returning None.

    Returns:
        Optional[Dict[str, Any]]: The JSON response, or None on error
    """
    if url is None:
        raise ValueError("URL must be provided")

    if motor is None:
        endpoint = "{}/status".format(url.rstrip("/"))
    else:
        endpoint = "{}/motor/{}/status".format(url.rstrip("/"), motor)
    return _send(requests.get, endpoint, timeout=timeout,
                 what="checking the status", url=url, motor=motor,
                 raise_on_error=raise_on_error)


def list_motors(url: str = DEFAULT_URL, timeout: Optional[float] = 5,
                raise_on_error: bool = False) -> Optional[Dict[str, Any]]:
    """List the motors the server was started with, and their pins."""
    return _send(requests.get, "{}/motors".format(url.rstrip("/")),
                 timeout=timeout, what="listing motors", url=url, motor=None,
                 raise_on_error=raise_on_error)


if __name__ == '__main__':
    logging.basicConfig(level=logging.INFO)
    url = DEFAULT_URL
    print(list_motors(url=url))
    run_motor(steps=20000, url=url, direction="clockwise", motor="a")
    status = check_status(url=url, motor="a")
    if status:
        print(f"Motor status: {status}")
