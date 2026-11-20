"""Exceptions raised when a pump request does not fully succeed.

Catch ``SyringePumpError`` to handle every failure; the subclasses say which
kind it was. Every exception carries what is known about the move:

    reply            the server's JSON reply, if one arrived (dict or None)
    motor, url       which motor on which server
    name             the SyringePump's label, e.g. "ctb" ("" if unset)
    steps_requested  steps the move asked for (None if not a move)
    steps_completed  steps the driver was actually sent, when known, else None
    volume_completed_ul  steps_completed as a volume, when SyringePump knows it
    stop_sent        True if a stop was sent while cleaning up a timeout
"""


class SyringePumpError(RuntimeError):
    """A move (or other pump request) did not fully complete.

    Base class: callers that only need "did it work?" catch this.
    """

    def __init__(self, detail, *, reply=None, motor=None, url=None,
                 steps_requested=None, steps_completed=None, stop_sent=False,
                 name="", action=None):
        super().__init__(detail)
        self.detail = detail
        self.reply = reply
        self.motor = motor
        self.url = url
        self.steps_requested = steps_requested
        self.steps_completed = steps_completed
        self.stop_sent = stop_sent
        self.name = name
        self.action = action            # e.g. "Dispensing 500 uL", set by SyringePump
        self.volume_completed_ul = None

    def __str__(self):
        where = "motor {!r} at {}".format(self.motor, self.url) if self.motor \
            else "default motor at {}".format(self.url)
        if self.name:
            where = "syringe {!r} ({})".format(self.name, where)
        head = "{} on {} failed".format(self.action, where) if self.action \
            else "Request to {} failed".format(where)
        text = "{}: {}.".format(head, self.detail.rstrip("."))

        if self.steps_requested is not None:      # it was a move
            if self.steps_completed is None:
                text += " The volume actually moved is unknown."
            else:
                text += " {} of {} steps were completed".format(
                    self.steps_completed, self.steps_requested)
                if self.volume_completed_ul is not None:
                    text += " (about {:.1f} uL)".format(self.volume_completed_ul)
                text += "."
        if self.stop_sent:
            text += " A stop was sent to the motor."
        return text


class PumpUnreachableError(SyringePumpError):
    """No reply: connection refused, DNS failure, or the connection dropped."""


class PumpBusyError(SyringePumpError):
    """HTTP 409: the motor was already moving, so this move never started."""


class PumpRejectedError(SyringePumpError):
    """HTTP 400 / 404 / 500 (or another non-2xx): the server refused or failed
    the request. ``detail`` carries the server's message."""


class PumpTimeoutError(SyringePumpError):
    """No reply within the client-side timeout. The motor may still be moving."""


class PartialMoveError(SyringePumpError):
    """HTTP 200 but the move did not finish, e.g. status "stopped"."""
