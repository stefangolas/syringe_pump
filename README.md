# Syringe Pump

A Raspberry Pi syringe pump controller: a Flask server on the Pi driving one or
two A4988 stepper drivers, and a Python client library for the controller PC.

- [Hardware: two-motor pinout](#hardware-two-motor-pinout)
- [Flashing a Pi](#flashing-a-pi)
- [HTTP API](#http-api)
- [Client library](#client-library)

## Hardware: two-motor pinout

Two independent motors, each on its own A4988. BCM numbering is what the
software uses; the physical header pin is what you actually count to when
wiring. This is the pinout the image ships with, declared in
[`pi-image/pi-app.env`](pi-image/pi-app.env) as:

```
MOTORS='a:22,23,17,27,25 b:5,6,13,19,26'
```

| A4988 signal | Motor **a** BCM | Motor **a** pin | Motor **b** BCM | Motor **b** pin |
|---|---|---|---|---|
| DIR  | GPIO22 | 15 | GPIO5  | 29 |
| STEP | GPIO23 | 16 | GPIO6  | 31 |
| MS1  | GPIO17 | 11 | GPIO13 | 33 |
| MS2  | GPIO27 | 13 | GPIO19 | 35 |
| MS3  | GPIO25 | 22 | GPIO26 | 37 |

Motor **b**'s five signals are physical pins 29, 31, 33, 35, 37 — five
consecutive positions in the header's odd column, with GND on pin 39 right
below them. That is deliberate: a second driver adds one contiguous ribbon
rather than five wires scattered across the header.

### Why these pins

No signal here touches a peripheral bus, so nothing has to be given up to add
the second motor:

- **I²C** (GPIO2/3, pins 3/5) — free
- **SPI** (GPIO7–11, pins 26/24/21/19/23) — free
- **UART** (GPIO14/15, pins 8/10) — free

That last one matters. `MotorServer.__init__`'s old defaults were
`mode_pins=(14, 15, 18)`, which sits on the UART lines, while its own `main()`
passed `(17, 27, 25)` instead — the code carried two different answers. The
manifest now states one, and the server is always started with it explicitly.

### Per-driver wiring, both drivers alike

| A4988 pin | Connect to |
|---|---|
| VMOT, GND | Motor supply (8–35 V) and its ground |
| VDD, GND | Pi 5 V (pin 2 or 4) and Pi GND (pin 6, 9, 14, 20, 25, 30, 34 or 39) |
| 1A / 1B / 2A / 2B | The two motor coils |
| RESET + SLEEP | Bridge them together, then to VDD |
| ENABLE | GND — see below |
| DIR, STEP, MS1–MS3 | Per the table above |

Put a 100 µF electrolytic across VMOT/GND at each driver, and share a common
ground between the motor supply and the Pi.

### ENABLE, and what the driver class does not do

`A4988Nema` has **no enable-pin support** — it drives DIR, STEP and MS1–MS3 and
nothing else. So tie each driver's ENABLE to GND, which holds it permanently
enabled. The cost is that the coils stay energised whenever the Pi is on: the
motors hold position, and both driver and motor run warm. Budget for that
thermally, or fit heatsinks.

`run_motor.py` does drive an enable pin (GPIO24) by hand, outside the class.
That is a standalone script, not the server path, and it only ever covered one
motor. If you want the server to de-energise idle motors, that needs an enable
pin per motor added to `A4988Nema` — currently unimplemented, and a real
change rather than a config tweak.

### Running one motor instead of two

Drop the second entry. `MOTORS='a:22,23,17,27,25'` gives a single-motor pump,
and the flasher asks "how many motors?" so one image serves both builds. With
MS1–MS3 strapped in hardware instead of driven, use the two-pin form:
`a:22,23` — the driver is then passed `(-1,-1,-1)` and leaves those pins alone.

## Flashing a Pi

`pi-image/` builds a ready-to-flash image with the app, its dependencies, the
autostarting service and the network configuration all baked in. Flash it and
switch the Pi on: no first-boot provisioning, no two-stage boot, and **the Pi
never needs a network**. See [`pi-image/README.md`](pi-image/README.md).

### macOS / Linux

```bash
curl -fsSL https://raw.githubusercontent.com/stefangolas/syringe_pump/main/pi-image/bootstrap.sh | sudo bash
```

### Windows

From an **administrator** PowerShell:

```powershell
irm https://raw.githubusercontent.com/stefangolas/syringe_pump/main/pi-image/bootstrap.ps1 | iex
```

Both download the CI-audited image, verify its published SHA-256, write it, and
then **prompt for this card's settings** — address, prefix, gateway, hostname,
port, motor count and password. Press Enter to accept the default shown in
brackets.

Those answers land in `syringe-pump.conf` on the card's FAT boot partition,
which any machine can mount. To re-address an instrument later, edit that file
and reboot the Pi — no reflash and no rebuild:

```powershell
.\bootstrap.ps1 -ConfigureOnly E:      # just rewrite the settings
```

An invalid value is refused as a whole, so a typo cannot strand the instrument
on an unreachable address; the result is logged to `syringe-pump-firstboot.log`
beside the config, on the same partition.

### The default link has no gateway and no DNS

With neither set, the Pi has no default route, so it can only be reached from a
host on the same switch. Give the controller PC's wired NIC a static address on
the same subnet, with **no gateway**, and leave Wi-Fi alone so the PC keeps
internet. The flasher prints the exact command for your chosen address.

> **The server has no authentication.** Anyone who can reach the port can drive
> the motors. If you set a gateway and put the instrument on the lab LAN, that
> means anyone on the LAN.

## HTTP API

Each motor is addressed by its id, so the two are commanded independently.

| Method | Path | Does |
|---|---|---|
| `GET` | `/motors` | List configured motors, their pins, and which is default |
| `POST` | `/motor/<id>/run` | Move that motor |
| `POST` | `/motor/<id>/stop` | Ask that motor to stop mid-move |
| `GET` | `/motor/<id>/status` | Whether that motor is moving, and if a stop is pending |
| `POST` | `/run_motor` | Alias for the **first** motor — kept for older clients |
| `POST` | `/stop_motor` | Alias for the first motor |
| `GET` | `/status` | Server liveness |

```bash
# Move motor a and motor b at the same time
curl -X POST http://10.194.22.184:5000/motor/a/run \
     -H 'Content-Type: application/json' \
     -d '{"steps": 600, "direction": "clockwise", "steptype": "Half", "stepdelay": 0.0005}'

# Stop only motor a; b keeps going
curl -X POST http://10.194.22.184:5000/motor/a/stop
```

`run` holds the response open for the duration of the move and then reports
`"success"`, or `"stopped"` if a stop arrived first. A second `run` for a motor
that is already moving gets **409** rather than interleaving steps on the same
STEP pin. An unknown steptype gets **400**.

## Client library

```python
from syringe_pump import SyringePump

# One SyringePump per motor, same server
left  = SyringePump(url="http://10.194.22.184:5000", motor="a")
right = SyringePump(url="http://10.194.22.184:5000", motor="b")

left.aspirate_vol(100)    # draw 100 uL
left.dispense_vol(100)    # push it back out
left.stop()               # abort a move in progress
print(left.check_status())
```

Volume is converted to steps from the syringe geometry at the top of
`syringe_pump/syringe.py` (barrel radius, thread pitch, step angle) — check
those constants match your hardware before trusting a volume.

Pass `simulating=True` to make the motion calls no-ops.

`rinse_trough()` needs a pump array object supplying `pump_by_number()`, passed
in as `rinse_pump_array`. Nothing in this repo provides one.

## Requirements

- **Controller PC:** Python 3.6+, `requests`
- **Pi:** built into the image — Flask, Flask-Caching, Redis, and `RPi.GPIO`
  from Raspberry Pi OS's own `python3-rpi.gpio` package

## License

MIT License
