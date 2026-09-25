# pi-image

Builds a ready-to-flash Raspberry Pi image with the application, its
dependencies, an autostarting service and a static-IP ethernet link baked in.

Flash it and switch the Pi on. There is no first-boot provisioning, no two-stage
boot, and **the Pi never needs a network**.

Per-card settings — address, hostname, port, motor count, password — are chosen
by the flasher and written to the card's FAT boot partition, so one image serves
every instrument and re-addressing one needs no rebuild.

## Why this shape

The obvious approach is to flash stock Raspberry Pi OS and configure it on first
boot. The sibling `transfer_station` repo built that first, and it cost:
a `systemd.run=` hook whose path depends on the OS release, Windows volumes that
sometimes have no drive letter, CRLF mangling the shebang of the first-boot
script, a Pi with no RTC whose clock made `apt` reject repositories, and a 23 MB
dependency bundle to avoid needing internet on the device.

Every one of those exists only because work was deferred to the device. Doing it
at build time, in a chroot on a machine that can be tested, deletes the whole
category.

[`sdm`](https://github.com/gitbls/sdm) does the image customisation — the account
wizard, cloud-init, `machine-id`, root expansion — so we do not rediscover those
one bug at a time.

### Build time vs write time

The split is deliberate, and it is the one thing to understand here:

| | Decided at | Why |
|---|---|---|
| apt packages, Python venv, frozen lock, service unit | **Build** | Slow, needs a network and a solver. Doing it on the Pi is what the two-stage design got wrong. |
| Address, prefix, gateway, DNS, hostname, port, motor count, password, SSH key | **Write** | Just text. Differs per instrument, and needs to change without a 1 GB rebuild. |

Write-time settings go in `<app>.conf` on the FAT boot partition — FAT because a
Windows flashing host has to be able to write it, which is also why nothing here
depends on writing the ext4 root.

## Building

```bash
sudo PI_PASSWORD='your-password' ./pi-image/build.sh
```

Produces `syringe-pump-YYYY-MM-DD.img.xz`. CI builds and audits the compressed
image on every relevant push; `main` publishes the rolling `pi-image` release,
which the flashers download and verify by checksum.

## Flashing

See the [top-level README](../README.md#flashing-a-pi). Both flashers download
the audited image, verify its published SHA-256, write it, then prompt for this
card's settings.

To change settings on a card that already has the image — no re-write:

```powershell
.\bootstrap.ps1 -ConfigureOnly E:
```
```bash
sudo bash bootstrap.sh --configure-only /media/$USER/bootfs
```

Or edit `syringe-pump.conf` on the boot partition by hand and reboot the Pi. It
is read on **every** boot.

## Updating a Pi that is already running

`install-on-pi.sh` installs this configuration onto a Pi reached over SSH,
without reflashing. It uses the same manifest, the same `render-motor-args.sh`
and the same EnvironmentFile indirection as the image, so a hand-updated Pi and
a freshly flashed one end up configured identically.

It deliberately leaves the network alone unless `--with-network` is passed:
applying a static address over the SSH session you are using to run it would drop
that session. See the [top-level README](../README.md#updating-a-pi-that-is-already-running).

## Configuring

`pi-app.env` is the whole per-project interface. `build.sh`, `cscript.sh`,
`firstboot.sh` and `render-motor-args.sh` are shared verbatim with
`transfer_station`; only the manifest differs.

| Key | Is |
|---|---|
| `APP_NAME`, `PI_HOSTNAME`, `PI_USER` | Identity. `APP_NAME` names the unit, the config file and the log. |
| `REPO_DEST` | Where the app lands on the Pi |
| `APT_PACKAGES` | Packages sdm installs; C extensions and services only |
| `SERVER_PROJECT` | Directory holding the frozen `pyproject.toml` + `uv.lock` the venv is built from |
| `PYTHON_IMPORTS` | Modules that must import in the finished venv |
| `REPO_EXCLUDES` | Paths kept out of the image |
| `APP_EXEC`, `SERVICE_REQUIRES` | The unit's `ExecStart` and its dependency |
| `MOTORS` | One entry per motor: `<id>:<dir>,<step>[,<ms1>,<ms2>,<ms3>]` |
| `ETH_*`, `SERVER_PORT` | Network and port defaults, and the flasher's prompt defaults |
| `IMAGE_*`, `SDM_*`, `UV_VERSION` | Pinned external inputs |

### The EnvironmentFile indirection

`APP_EXEC` deliberately leaves `$PUMP_PORT` and `$MOTOR_ARGS` unexpanded.
`build.sh` substitutes `${VENV}` and `${REPO_DEST}`, but those two are left for
**systemd** to expand from `EnvironmentFile=/etc/<app>.env`. That is the only
reason `firstboot.sh` can change the port or the motor set: it rewrites one small
file, and no unit is regenerated and no `daemon-reload` is needed.

If someone ever substitutes them at build time, the card's config silently stops
affecting them. `tests/test_bootstrap.sh` and `tests/test_built_image.sh` both
check for that.

### The motor set

`MOTORS` is validated and rendered by `render-motor-args.sh`, which is the single
source of truth for what a valid pinout is — used by `build.sh` at build time and
by `firstboot.sh` at boot, so both produce identical arguments. It rejects a
duplicate id, a pin outside BCM 0–27, the wrong number of pins, and a pin
assigned to two motors (which would be silent: both motors would step together).

The wiring table is in the [top-level README](../README.md#hardware-two-motor-pinout).

## Failure behaviour

`firstboot.sh` validates everything **before** changing anything. An invalid
value means nothing is applied and the previous configuration stands, so a typo
cannot strand the instrument on an unreachable address. The unit fails visibly
(`systemctl status syringe-pump-firstboot`) and the reason is logged to
`syringe-pump-firstboot.log` on the boot partition — which matters precisely
because a wrong address is when you cannot reach the Pi to read the journal.

A card with no config file keeps the baked defaults and exits cleanly. That is
the intended path for a card nobody customised.

The config file is **parsed key by key, never sourced**. It is written by a
flasher on someone's laptop and lives on a removable partition, so it is the
least trustworthy input in the system; sourcing it would execute it as root.

## Tests

```bash
pi-image/tests/run-all.sh                                     # everything runnable off a Pi
sudo bash pi-image/tests/test_built_image.sh image.img.xz     # audit a built image
```

| Suite | Runs | Covers |
|---|---|---|
| `test_motor_server.py` | anywhere | The two-motor server with `RPi.GPIO` shimmed: that two motors move **concurrently**, that stopping one leaves the other running, that a busy motor returns 409, that each drives only its own pins, and that the legacy routes still hit the first motor |
| `test_firstboot.sh` | anywhere | Write-time config against a fake root: applied exactly, isolated vs routed profiles, invalid input changing nothing, the password scrubbed off the card, idempotence across boots, CRLF configs, and that the file is parsed rather than executed |
| `test_cscript_phase0.sh` | Linux | sdm phase 0 for real against a fake mounted image: placement, excludes, modes, the frozen project reaching the image, and that a missing staging dir is a hard error |
| `test_bootstrap.sh` | anywhere | That the flashers' hardcoded defaults still equal the manifest, that they write the keys `firstboot.sh` reads, and that the README's pinout covers every configured pin |
| `test_built_image.sh` | Linux + root | The finished `.img.xz`: partitions, account, groups, installed deps, enabled units, the EnvironmentFile indirection, all motors configured, the network profile, and no build tooling or password left behind |

### What the tests do *not* catch

Nothing in CI boots a Pi:

- `systemd` actually running the units, and the firstboot ordering holding
- NetworkManager actually applying the profile to a real NIC
- Anything GPIO, driver or motor related — `RPi.GPIO` is shimmed, so step
  *timing* and real A4988 behaviour are untested
- Whether `ETH_PREFIX` matches your actual subnet

A test flash onto a spare card remains the only real validation of the boot and
network path.
