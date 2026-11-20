# Syringe Pump

A Raspberry Pi syringe pump controller: a Flask server on the Pi driving up to
three A4988 stepper drivers, and a Python client library for the controller PC.

- [Client setup](CLIENT.md) — driving the pump from a controller PC
- [Hardware: motor pinout](#hardware-motor-pinout)
- [Flashing a Pi](#flashing-a-pi)
- [HTTP API](#http-api)
- [Client library](#client-library)

## Hardware: motor pinout

Up to three independent motors, each on its own A4988. BCM numbering is what
the software uses; the physical header pin is what you actually count to when
wiring. This is the pinout the image ships with, declared in
[`pi-image/pi-app.env`](pi-image/pi-app.env) as:

```
MOTORS='a:22,23,17,27,25 b:5,6,13,19,26 c:20,21,12,16,4'
```

Every Pi connection, as wired on the instrument. "Pin" is the physical header
pin; the GPIO numbers are what `MOTORS` lists.

| A4988 pin | Motor **a** | Motor **b** | Motor **c** |
|---|---|---|---|
| DIR    | pin 15 (GPIO22) | pin 29 (GPIO5)  | pin 38 (GPIO20) |
| STEP   | pin 16 (GPIO23) | pin 31 (GPIO6)  | pin 40 (GPIO21) |
| MS1    | pin 11 (GPIO17) | pin 33 (GPIO13) | pin 32 (GPIO12) |
| MS2    | pin 13 (GPIO27) | pin 35 (GPIO19) | pin 36 (GPIO16) |
| MS3    | pin 22 (GPIO25) | pin 37 (GPIO26) | pin 7 (GPIO4)   |
| ENABLE | pin 14 (GND)    | pin 34 (GND)    | pin 39 (GND)    |
| GND (logic side) | pin 6 (GND) | pin 30 (GND) | pin 25 (GND) |
| VDD    | pin 2 (5 V)     | pin 4 (5 V)     | pin 1 (3.3 V)   |
| RESET + SLEEP | jumpered together on the driver | same | same |

Header pins in use: 1, 2, 4, 6, 7, 11, 13, 14, 15, 16, 22, 25, 29, 30, 31, 32,
33, 34, 35, 36, 37, 38, 39, 40. GND pins 9 and 20 and 3.3 V pin 17 are still
free.

Motor **b**'s five signals are physical pins 29, 31, 33, 35, 37 — five
consecutive positions in the header's odd column. That is deliberate: a second
driver adds one contiguous ribbon rather than five wires scattered across the
header.

Motor **c**'s DIR, STEP, MS1 and MS2 sit at the bottom of the even column
(pins 32–40), interleaved with motor b's ground pins 30 and 34. Only MS3 has to
reach up to pin 7: it is the last free GPIO that is not on a bus. GPIO24
(pin 18) is also free, but `run_motor.py` drives it as an enable pin, so it was
left alone.

Motor c's VDD is on 3.3 V because both 5 V pins already feed a and b. That is
inside the A4988's 3–5.5 V logic range, and it suits the Pi better: at 5 V the
A4988 needs 3.5 V for a reliable logic high, while the Pi's GPIO outputs only
3.3 V. A and b work at 5 V, but with less margin.

### Why these pins

No signal here touches a peripheral bus, so nothing has to be given up to add
the second or third motor:

- **I²C** (GPIO2/3, pins 3/5) — free
- **SPI** (GPIO7–11, pins 26/24/21/19/23) — free
- **UART** (GPIO14/15, pins 8/10) — free

That last one matters. `MotorServer.__init__`'s old defaults were
`mode_pins=(14, 15, 18)`, which sits on the UART lines, while its own `main()`
passed `(17, 27, 25)` instead — the code carried two different answers. The
manifest now states one, and the server is always started with it explicitly.

### Per-driver wiring, every driver alike

| A4988 pin | Connect to |
|---|---|
| VMOT, GND | Motor supply (8–35 V) and its ground |
| VDD, GND | Pi 5 V or 3.3 V, and a Pi GND, per the table above |
| 1A / 1B / 2A / 2B | The two motor coils: 1A/1B one coil, 2A/2B the other |
| RESET + SLEEP | A short jumper between them on the driver; no wire to the Pi. The board pulls SLEEP high, and the jumper holds RESET high with it |
| ENABLE | A Pi GND — see below |
| DIR, STEP, MS1–MS3 | Per the table above |

The driver's two GND pins are connected on the board, so wiring the logic GND
to the Pi and the power GND to the supply gives them a common ground.

Put a 100 µF electrolytic across VMOT/GND at each driver, + leg to VMOT.
Set each driver's current limit with its potentiometer before running the
motor, and never connect or disconnect a motor while VMOT is live. Because
ENABLE is tied low (below),
every motor draws holding current whenever the Pi is on, so size the motor
supply for all of them at once.

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

### Running fewer motors

Drop trailing entries. `MOTORS='a:22,23,17,27,25'` gives a single-motor pump and
`MOTORS='a:22,23,17,27,25 b:5,6,13,19,26'` a two-motor one. The flasher asks
"how many motors?" (1, 2 or 3), so one image serves every build. With
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

## Updating a Pi that is already running

If a Pi is already set up and reachable over SSH, there is no need to reflash.

```bash
ssh chorylab@<pi>
cd ~/syringe_pump && git pull
sudo pi-image/install-on-pi.sh --dry-run      # see exactly what it would do
sudo pi-image/install-on-pi.sh
```

The `git pull` alone is operationally inert: the server still defaults to the
single motor `a:22,23,17,27,25` on the pins it already used, and `/run_motor`,
`/stop_motor` and `/status` behave as before. Further motors appear only once
more `--motor` flags are passed, which the installer does.

The installer's default is every motor in `pi-app.env`, which is now three. On a
Pi with only two drivers wired, pass the set explicitly:
`--motors "a:22,23,17,27,25 b:5,6,13,19,26"`.

`install-on-pi.sh` refreshes the frozen venv, installs the systemd service and
its `EnvironmentFile`, and starts the server. **It does not touch the network**,
because you are reading its output over SSH and applying a static address would
drop that session. Pass `--with-network` only from a console, or when the address
being set is the one you are already connected on.

| Option | Does |
|---|---|
| `--dry-run` | Print every action, change nothing |
| `--one-motor` | Run only the first motor in `pi-app.env` |
| `--motors "<spec>"` | Use a specific motor set |
| `--port <n>` | Serve on another port |
| `--with-network` | Also apply the static address — read the warning above |
| `--no-firstboot` | Skip the write-time config machinery |

It adapts to the machine rather than the manifest: the checkout location and its
owning user are taken from the filesystem, so a repo at a different path or owned
by a different account still works. A bad motor set is rejected before the venv
is touched, and any existing unit is kept as `<unit>.before-install`.

Afterwards, the port and motor set live in `/etc/syringe-pump.env`. Change either
by editing that file and running `sudo systemctl restart syringe-pump` — no unit
rewrite and no reinstall.

### The default link has no gateway and no DNS

With neither set, the Pi has no default route, so it can only be reached from a
host on the same switch. Give the controller PC's wired NIC a static address on
the same subnet, with **no gateway**, and leave Wi-Fi alone so the PC keeps
internet. The flasher prints the exact command for your chosen address.

> **The server has no authentication.** Anyone who can reach the port can drive
> the motors. If you set a gateway and put the instrument on the lab LAN, that
> means anyone on the LAN.

## HTTP API

Each motor is addressed by its id, so each is commanded independently.

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

Full setup, including the static address the controller PC needs, is in
[CLIENT.md](CLIENT.md).

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

Volume is converted to steps from the syringe's barrel radius and the drive's
thread pitch and step angle. The radius is set per pump and defaults to the
30 mL syringe (11 mm); pick another from `SYRINGE_RADII` or pass your own in mm:

```python
from syringe_pump import SyringePump, SYRINGE_RADII

small = SyringePump(url="http://10.194.22.184:5000", motor="c",
                    syringe_radius=SYRINGE_RADII["10mL"])
```

Thread pitch and step angle are fixed by the motor and lead screw, so they stay
as constants at the top of `syringe_pump/syringe.py`. Check all three against
your hardware before trusting a volume — barrel sizes vary by brand.

The conversion is step-mode aware. Each pump has a `steptype` (default
`"Full"`; also `"Half"`, `"1/4"`, `"1/8"`, `"1/16"`), and the step count is
scaled to match, so the same volume comes out in every mode. Override it per
move with `dispense_vol(100, steptype="1/8")`. Finer modes run smoother but send
more pulses, so a move takes proportionally longer at the same step delay. If a
driver's MS1–MS3 are strapped in hardware, set `steptype` to match the
strapping: the server cannot change the mode, so a mismatch gives the wrong
volume.

Speed is set per pump with `stepdelay` (default `0.0005`, about 1000 full
steps/s, smooth on motor c with a syringe fitted); one step takes
`2 × stepdelay`. In Full mode a motor can resonate in a narrow speed band,
buzzing and skipping steps there while running smoothly above and below it.
Motor c (unloaded) is smooth in Full at `0.01`, `0.001` and `0.0005`, but
buzzes at `0.005` (100 steps/s). Avoid that band, or use a finer `steptype`,
which smooths it out: Half at `0.002` is also smooth.

```python
c = SyringePump(url=URL, motor="c")                     # Full, 0.0005: the defaults
slow = SyringePump(url=URL, motor="c", stepdelay=0.001)  # Full, 500 steps/s
```

Pass `simulating=True` to make the motion calls no-ops.

`rinse_trough()` needs a pump array object supplying `pump_by_number()`, passed
in as `rinse_pump_array`. Nothing in this repo provides one.

## Requirements

- **Controller PC:** Python 3.6+, `requests`
- **Pi:** built into the image — Flask, Flask-Caching, Redis, and `RPi.GPIO`
  from Raspberry Pi OS's own `python3-rpi.gpio` package

## License

MIT License
