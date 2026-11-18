# Client setup

How to drive the pump from a controller PC. The Pi runs the server; this is
everything on the other end of the cable.

## 1. Get on the Pi's network

This is the step that actually blocks people, so do it first.

The Pi has a **static address with no gateway and no DNS**. Nothing hands out
addresses on that link, so your PC will not reach it until you give the wired
adapter an address on the same subnet yourself. Until then `ping` fails, and it
fails in a way that looks like the Pi is dead rather than like a routing
problem.

The instrument is at **`192.168.10.2`**, so give the PC something else on
`192.168.10.0/24` — `.3` is free.

**Windows** (administrator PowerShell):

```powershell
New-NetIPAddress -InterfaceAlias Ethernet -IPAddress 192.168.10.3 -PrefixLength 24
```

Persists across reboots. Undo with
`Remove-NetIPAddress -IPAddress 192.168.10.3 -Confirm:$false`.

**Linux:**

```bash
ip -br link                                    # find the wired interface
sudo ip addr add 192.168.10.3/24 dev eth0
```

**macOS:**

```bash
networksetup -listallhardwareports             # find the wired interface
sudo ifconfig en5 192.168.10.3/24
```

**No gateway and no DNS on that adapter.** Leave Wi-Fi alone — it keeps the
default route, so the PC still has internet while talking to the Pi over the
cable. Adding a gateway here is how you break both.

Check it:

```bash
ping 192.168.10.2
curl http://192.168.10.2:5100/motors
```

`/motors` is the useful one: it reports each motor with the GPIO pins it is
actually driving, so it confirms the server is up *and* that its configuration
matches the hardware.

## 2. Install the client

Only `requests` is needed — the Flask/Redis/GPIO dependencies are server-side
and never installed here.

```bash
git clone https://github.com/stefangolas/syringe_pump.git
cd syringe_pump
pip install -e .
```

## 3. Drive it

One `SyringePump` per motor, all pointed at the same server:

```python
from syringe_pump import SyringePump

URL = "http://192.168.10.2:5100"

left   = SyringePump(url=URL, motor="a")
right  = SyringePump(url=URL, motor="b")
third  = SyringePump(url=URL, motor="c")

left.aspirate_vol(100)     # draw 100 uL
left.dispense_vol(100)     # push it back
print(left.check_status())  # {'id': 'a', 'busy': False, ...}
left.stop()                # abort a move already running
```

`motor=` is what keeps them independent. **Omit it and every command goes to
motor `a`** via the legacy single-motor routes, which is the one mistake here
that fails silently — the wrong motor moves and nothing reports an error.

Pass `simulating=True` to make the motion calls no-ops without touching the
instrument.

### Raw HTTP

Nothing about the API needs the Python client:

```bash
curl -X POST http://192.168.10.2:5100/motor/a/run \
     -H 'Content-Type: application/json' \
     -d '{"steps": 600, "direction": "clockwise", "steptype": "Half", "stepdelay": 0.0005}'

curl -X POST http://192.168.10.2:5100/motor/a/stop
curl http://192.168.10.2:5100/motor/a/status
```

| Method | Path | Does |
|---|---|---|
| `GET` | `/motors` | Every motor, its pins, and which is default |
| `POST` | `/motor/<id>/run` | Move that motor |
| `POST` | `/motor/<id>/stop` | Stop that motor mid-move |
| `GET` | `/motor/<id>/status` | Whether it is moving, and if a stop is pending |
| `POST` | `/run_motor`, `/stop_motor` | Legacy aliases for the **first** motor |
| `GET` | `/status` | Server liveness only |

## 4. Four things that will bite you

**`run` blocks for the whole move.** A 15,000-step stroke holds the HTTP
response open for ~8 s. That is intentional — the reply reports the completed
move — but it means a naive client with a short timeout will give up while the
motor is still going, and the motor does not stop when the client does. To
overlap two motors, fire both requests concurrently (threads, `asyncio`, or two
backgrounded `curl`s) rather than awaiting one then the other.

**A busy motor returns 409.** Commanding a motor that is already moving is
refused rather than queued, so overlapping steps can never corrupt a step count.
Treat 409 as "send a stop first", not as an error to retry blindly.

**Volume conversion is unverified.** `vol_to_steps()` derives steps from the
syringe's barrel radius plus the drive's thread pitch (0.8 mm) and step angle
(1.8°). The radius defaults to 11 mm (30 mL syringe); for another size pass
`syringe_radius=SYRINGE_RADII["10mL"]` or your own value in mm when creating the
`SyringePump`. Check all three against your actual hardware before trusting a
figure in microlitres — barrel sizes vary by brand, and nothing validates them.
The step count also scales with the pump's `steptype` (default `"Full"`), so
`"Half"` sends twice the pulses for the same volume.

**Step timing is not what you ask for.** Below roughly `stepdelay=0.0005`, the
per-step Python overhead dominates: a stroke measured at 8.5 s against a
predicted 6 s, consistently, on both motors. Fine for "about this fast",
unreliable for anything you would calibrate against. Measure empirically if the
rate matters.

## 5. Security

**There is no authentication.** Anyone who can reach the port can drive the
motors. The isolated link is what protects the instrument: with no gateway, only
a host on that same switch can see it. If you ever give the Pi a gateway and put
it on the lab LAN, that protection is gone.

## 6. When it does not work

| Symptom | Cause |
|---|---|
| `ping` fails | Your PC has no address on `192.168.10.0/24`. Step 1 |
| Connection refused | Server not running. On the Pi: `systemctl status syringe-pump` |
| Connection times out | Wrong subnet, or the packet is going out Wi-Fi. Check your route to `192.168.10.2` |
| `404 unknown motor` | That id is not configured. `GET /motors` lists the real ones |
| `409 busy` | Motor already moving. Stop it first |
| Commands work, nothing moves | Server-side wiring, not the client. `/motors` confirms the pins; the server cannot sense a motor, so it reports success either way |
| Wrong motor moves | `motor=` omitted, so it hit the legacy default-motor route |

For anything on the Pi itself — the service, its port, the motor set — see
[`pi-image/README.md`](pi-image/README.md) and the `install-on-pi.sh` section of
the [main README](README.md#updating-a-pi-that-is-already-running).
