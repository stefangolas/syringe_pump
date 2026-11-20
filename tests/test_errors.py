"""Failure handling in the client: run_motor(raise_on_error=True) and a strict
SyringePump raise a SyringePumpError subclass for every way a move can fail,
and the lenient modes keep the old return-None behaviour.

requests.post / requests.get are patched, so no server or hardware is needed.
Run:  pytest tests/
"""
from unittest import mock

import pytest
import requests

from syringe_pump import (SyringePump, SyringePumpError, PumpUnreachableError,
                          PumpBusyError, PumpRejectedError, PumpTimeoutError,
                          PartialMoveError, default_move_timeout, run_motor)
from syringe_pump.curl_requests import stop_motor, check_status
from syringe_pump.syringe import vol_per_step, vol_to_steps

URL = "http://pump.test:5000"


class FakeResponse:
    def __init__(self, status_code, body=None, reason="", json_ok=True):
        self.status_code = status_code
        self.reason = reason
        self._body = body
        self._json_ok = json_ok

    def json(self):
        if not self._json_ok:
            raise ValueError("not JSON")
        return self._body


def ok(steps=100, **extra):
    body = {"status": "success", "motor": "c", "steps": steps,
            "steps_completed": steps, "direction": "clockwise", "message": "ran"}
    body.update(extra)
    return FakeResponse(200, body)


BUSY = FakeResponse(409, {"status": "busy", "motor": "c",
                          "message": "motor c is already running; POST /motor/c/stop first"})
STOPPED = FakeResponse(200, {"status": "stopped", "motor": "c", "steps": 100,
                             "steps_completed": 40, "message": "motor c stopped after 40 of 100 steps"})
REJECTED = {
    400: FakeResponse(400, {"status": "error", "message": "invalid steptype: '1/256'"}),
    404: FakeResponse(404, {"status": "error", "message": "unknown motor 'z'; configured: a, b, c"}),
    500: FakeResponse(500, {"status": "error", "motor": "c", "steps": 100, "steps_completed": 12,
                            "message": "motor c failed after 12 of 100 steps: OSError: gpio"}),
}


@pytest.fixture
def post():
    with mock.patch("requests.post") as p:
        yield p


@pytest.fixture
def get():
    with mock.patch("requests.get") as g:
        yield g


def strict_pump(**kw):
    kw.setdefault("name", "ctb")
    return SyringePump(url=URL, motor="c", **kw)


# --- run_motor(raise_on_error=True) ------------------------------------------

def test_run_motor_success_returns_reply(post):
    post.return_value = ok()
    reply = run_motor(steps=100, url=URL, motor="c", raise_on_error=True)
    assert reply["status"] == "success"


def test_run_motor_connection_refused(post):
    post.side_effect = requests.ConnectionError("refused")
    with pytest.raises(PumpUnreachableError) as e:
        run_motor(steps=100, url=URL, motor="c", raise_on_error=True)
    assert e.value.steps_completed is None


def test_run_motor_connect_timeout_is_unreachable(post):
    post.side_effect = requests.ConnectTimeout("no route")
    with pytest.raises(PumpUnreachableError):
        run_motor(steps=100, url=URL, motor="c", timeout=1, raise_on_error=True)


def test_run_motor_read_timeout(post):
    post.side_effect = requests.ReadTimeout("slow")
    with pytest.raises(PumpTimeoutError):
        run_motor(steps=100, url=URL, motor="c", timeout=1, raise_on_error=True)


def test_run_motor_busy_carries_server_message(post):
    post.return_value = BUSY
    with pytest.raises(PumpBusyError) as e:
        run_motor(steps=100, url=URL, motor="c", raise_on_error=True)
    assert "already running" in str(e.value)
    assert e.value.steps_completed == 0          # refused before moving
    assert e.value.reply["status"] == "busy"


@pytest.mark.parametrize("code", [400, 404, 500])
def test_run_motor_rejected_carries_server_message(post, code):
    post.return_value = REJECTED[code]
    with pytest.raises(PumpRejectedError) as e:
        run_motor(steps=100, url=URL, motor="c", raise_on_error=True)
    assert REJECTED[code]._body["message"] in str(e.value)
    assert e.value.steps_completed == (12 if code == 500 else 0)


def test_run_motor_500_from_old_server_has_unknown_steps(post):
    post.return_value = FakeResponse(500, {"status": "error", "message": "Traceback ..."})
    with pytest.raises(PumpRejectedError) as e:
        run_motor(steps=100, url=URL, motor="c", raise_on_error=True)
    assert e.value.steps_completed is None
    assert "unknown" in str(e.value)


def test_run_motor_stopped_is_partial_move(post):
    post.return_value = STOPPED
    with pytest.raises(PartialMoveError) as e:
        run_motor(steps=100, url=URL, motor="c", raise_on_error=True)
    assert e.value.steps_completed == 40
    assert "40 of 100 steps" in str(e.value)


def test_run_motor_non_json_reply(post):
    post.return_value = FakeResponse(200, json_ok=False)
    with pytest.raises(SyringePumpError):
        run_motor(steps=100, url=URL, motor="c", raise_on_error=True)


@pytest.mark.parametrize("failure", [
    requests.ConnectionError("refused"), requests.ReadTimeout("slow"),
    BUSY, REJECTED[400], REJECTED[404], REJECTED[500]])
def test_run_motor_lenient_returns_none(post, failure):
    if isinstance(failure, Exception):
        post.side_effect = failure
    else:
        post.return_value = failure
    assert run_motor(steps=100, url=URL, motor="c") is None


def test_run_motor_lenient_passes_stopped_reply_through(post):
    post.return_value = STOPPED
    assert run_motor(steps=100, url=URL, motor="c")["status"] == "stopped"


def test_stop_and_status_raise_when_asked(post, get):
    post.side_effect = requests.ConnectionError("refused")
    get.side_effect = requests.ConnectionError("refused")
    with pytest.raises(PumpUnreachableError):
        stop_motor(url=URL, motor="c", raise_on_error=True)
    with pytest.raises(PumpUnreachableError):
        check_status(url=URL, motor="c", raise_on_error=True)
    assert stop_motor(url=URL, motor="c") is None
    assert check_status(url=URL, motor="c") is None


# --- strict SyringePump -------------------------------------------------------

def test_strict_success_returns_reply(post):
    post.return_value = ok()
    assert strict_pump().dispense_vol(100)["status"] == "success"


def test_strict_connection_refused(post):
    post.side_effect = requests.ConnectionError("refused")
    with pytest.raises(PumpUnreachableError) as e:
        strict_pump().aspirate_vol(100)
    text = str(e.value)
    assert "'ctb'" in text and "'c'" in text and URL in text
    assert "Aspirating 100 uL" in text
    assert "unknown" in text


def test_strict_timeout_while_busy_sends_stop(post, get):
    stop_reply = FakeResponse(200, {"status": "success", "message": "stop requested"})
    post.side_effect = [requests.ReadTimeout("slow"), stop_reply]
    get.return_value = FakeResponse(200, {"id": "c", "busy": True, "status": "running"})
    with pytest.raises(PumpTimeoutError) as e:
        strict_pump().dispense_vol(100)
    assert e.value.stop_sent is True
    assert post.call_args_list[1].args[0] == URL + "/motor/c/stop"
    assert "stop was sent" in str(e.value)


def test_strict_timeout_with_server_gone_keeps_original_error(post, get):
    post.side_effect = requests.ReadTimeout("slow")
    get.side_effect = requests.ConnectionError("refused")
    with pytest.raises(PumpTimeoutError) as e:
        strict_pump().dispense_vol(100)
    assert e.value.stop_sent is False
    assert post.call_count == 1                 # no stop attempted


def test_strict_timeout_cleanup_crash_does_not_hide_timeout(post):
    post.side_effect = requests.ReadTimeout("slow")
    with mock.patch("syringe_pump.syringe.check_status", side_effect=RuntimeError("boom")):
        with pytest.raises(PumpTimeoutError) as e:
            strict_pump().dispense_vol(100)
    assert e.value.stop_sent is False


def test_strict_busy(post):
    post.return_value = BUSY
    with pytest.raises(PumpBusyError) as e:
        strict_pump().dispense_vol(100)
    assert "already running" in str(e.value)


@pytest.mark.parametrize("code", [400, 404, 500])
def test_strict_rejected(post, code):
    post.return_value = REJECTED[code]
    with pytest.raises(PumpRejectedError) as e:
        strict_pump().dispense_vol(100)
    assert REJECTED[code]._body["message"] in str(e.value)


def test_strict_stopped_reports_volume_completed(post):
    post.return_value = STOPPED
    with pytest.raises(PartialMoveError) as e:
        strict_pump().dispense_vol(100)
    assert e.value.steps_completed == 40
    assert e.value.volume_completed_ul == pytest.approx(40 * vol_per_step())
    assert "40 of 100 steps" in str(e.value) and "uL)" in str(e.value)


@pytest.mark.parametrize("strict", [True, False])
def test_simulation_returns_success_without_http(post, strict):
    pump = SyringePump(url=URL, motor="c", simulating=True, strict=strict)
    assert pump.dispense_vol(100) == {"status": "success", "simulated": True}
    assert pump.aspirate_vol(100) == {"status": "success", "simulated": True}
    post.assert_not_called()


def test_non_strict_keeps_old_behaviour(post):
    post.side_effect = requests.ConnectionError("refused")
    assert SyringePump(url=URL, motor="c", strict=False).dispense_vol(100) is None
    assert post.call_args.kwargs["timeout"] is None


# --- timeouts -----------------------------------------------------------------

def test_default_timeout_formula():
    assert default_move_timeout(15000, 0.0005) == pytest.approx(15000 * 2 * 0.0005 * 1.5 + 10)


def test_strict_uses_computed_timeout(post):
    post.return_value = ok()
    strict_pump(stepdelay=0.001).dispense_vol(5000)
    steps = vol_to_steps(5000)
    assert post.call_args.kwargs["timeout"] == pytest.approx(steps * 2 * 0.001 * 1.5 + 10)


def test_timeout_overrides(post):
    post.return_value = ok()
    pump = strict_pump(move_timeout_s=99)
    pump.dispense_vol(100)
    assert post.call_args.kwargs["timeout"] == 99
    pump.dispense_vol(100, move_timeout_s=7)
    assert post.call_args.kwargs["timeout"] == 7


# --- hierarchy ----------------------------------------------------------------

@pytest.mark.parametrize("cls", [PumpUnreachableError, PumpBusyError, PumpRejectedError,
                                 PumpTimeoutError, PartialMoveError])
def test_every_error_is_a_syringe_pump_error(cls):
    assert issubclass(cls, SyringePumpError)
    assert issubclass(cls, RuntimeError)
