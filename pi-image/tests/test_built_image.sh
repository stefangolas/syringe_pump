#!/usr/bin/env bash
# Audit the exact compressed image that CI will publish.
set -euo pipefail

IMAGE="${1:-}"
[ -f "$IMAGE" ] || { echo "usage: $0 image.img.xz" >&2; exit 2; }
[ "$(id -u)" -eq 0 ] || { echo "must run as root" >&2; exit 2; }

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
# shellcheck disable=SC1091
. "$REPO_ROOT/pi-image/pi-app.env"

for tool in xz losetup mount umount chroot systemctl stat; do
    command -v "$tool" >/dev/null || { echo "missing tool: $tool" >&2; exit 2; }
done

WORK="$(mktemp -d)"
MNT="$WORK/root"
RAW="$WORK/image.img"
LOOP=""
cleanup() {
    set +e
    mountpoint -q "$MNT/boot/firmware" && umount "$MNT/boot/firmware"
    mountpoint -q "$MNT" && umount "$MNT"
    [ -n "$LOOP" ] && losetup -d "$LOOP"
    rm -rf "$WORK"
}
trap cleanup EXIT

ok() { echo "ok: $*"; }
fail() { echo "FAIL: $*" >&2; exit 1; }

echo ">> checking and decompressing the published image"
xz -t "$IMAGE"
xz -dc "$IMAGE" > "$RAW"
LOOP="$(losetup --show -fP "$RAW")"
[ -b "${LOOP}p1" ] && [ -b "${LOOP}p2" ] || fail "image does not have boot and root partitions"
mkdir -p "$MNT"
mount "${LOOP}p2" "$MNT"
mkdir -p "$MNT/boot/firmware"
mount "${LOOP}p1" "$MNT/boot/firmware"
ok "image partitions mount"

grep -qx "$PI_HOSTNAME" "$MNT/etc/hostname" || fail "hostname is not $PI_HOSTNAME"
grep -q "^$PI_USER:" "$MNT/etc/passwd" || fail "user $PI_USER is missing"
USER_GROUPS="$(chroot "$MNT" id -nG "$PI_USER")"
for group in sudo gpio dialout; do
    grep -qw "$group" <<<"$USER_GROUPS" || fail "$PI_USER is not in $group"
done
ok "identity and hardware groups"

for path in syringe_pump/motor_server.py syringe_pump/A4988.py \
            "$SERVER_PROJECT/uv.lock" "$SERVER_PROJECT/pyproject.toml" \
            .venv/bin/python; do
    [ -e "$MNT$REPO_DEST/$path" ] || fail "$REPO_DEST/$path is missing"
done
APP_UID="$(stat -c %u "$MNT$REPO_DEST")"
USER_UID="$(awk -F: -v user="$PI_USER" '$1 == user { print $3 }' "$MNT/etc/passwd")"
[ -n "$USER_UID" ] && [ "$APP_UID" = "$USER_UID" ] || fail "application has the wrong owner"
ok "application and frozen venv installed"

# Build-time tooling must not ship to the instrument.
for stray in pi-image/build.sh pi-image/cscript.sh pi-image/tests .git; do
    [ -e "$MNT$REPO_DEST/$stray" ] && fail "$stray should not be in the image"
done
ok "build-time tooling excluded from the image"

chroot "$MNT" dpkg-query -W redis-server python3-rpi.gpio network-manager >/dev/null
PYTHON_IMPORTS="$PYTHON_IMPORTS" chroot "$MNT" "$REPO_DEST/.venv/bin/python" - <<'PY'
import importlib
import importlib.util as u
import os
for name in os.environ["PYTHON_IMPORTS"].split(","):
    name = name.strip()
    if name:
        importlib.import_module(name)
assert u.find_spec("RPi.GPIO")
print("runtime imports ok")
PY
ok "apt and Python dependencies installed"

systemctl --root="$MNT" is-enabled "$APP_NAME.service" >/dev/null ||
    fail "$APP_NAME.service is not enabled"
systemctl --root="$MNT" is-enabled "$APP_NAME-firstboot.service" >/dev/null ||
    fail "$APP_NAME-firstboot.service is not enabled"
systemctl --root="$MNT" is-enabled ssh.service >/dev/null ||
    fail "ssh.service is not enabled"
UNIT="$MNT/etc/systemd/system/$APP_NAME.service"
grep -q "^User=$PI_USER$" "$UNIT" || fail "service runs as the wrong user"
grep -q "^Requires=$SERVICE_REQUIRES$" "$UNIT" || fail "service does not require Redis"
grep -q "^ExecStart=$REPO_DEST/.venv/bin/python " "$UNIT" || fail "service does not use the frozen venv"
ok "SSH, firstboot and application services enabled"

# --- the write-time configuration contract, in the finished image ---------
# The port and the motor set must reach the server through the EnvironmentFile,
# not be substituted into ExecStart -- that indirection is the only reason a
# card's config can change them without a rebuild.
grep -q "^EnvironmentFile=/etc/$APP_NAME.env$" "$UNIT" ||
    fail "the unit does not read /etc/$APP_NAME.env"
grep -q 'ExecStart=.*--port=\$PUMP_PORT' "$UNIT" ||
    fail "the port is baked into ExecStart instead of expanded at start"
grep -q 'ExecStart=.*\$MOTOR_ARGS' "$UNIT" ||
    fail "the motor set is baked into ExecStart instead of expanded at start"
[ -f "$MNT/etc/$APP_NAME.env" ] || fail "/etc/$APP_NAME.env is missing"
grep -q "^PUMP_PORT=$SERVER_PORT$" "$MNT/etc/$APP_NAME.env" ||
    fail "the baked EnvironmentFile has the wrong port"
grep -q '^MOTOR_ARGS=--motor ' "$MNT/etc/$APP_NAME.env" ||
    fail "the baked EnvironmentFile has no rendered motor arguments"
ok "port and motor set reach the server through the EnvironmentFile"

# Every motor in the manifest must be on the rendered command line, or the
# second motor silently does not exist on the instrument.
EXPECTED_ARGS="$(bash "$REPO_ROOT/pi-image/render-motor-args.sh" "$MOTORS")"
grep -qx "MOTOR_ARGS=$EXPECTED_ARGS" "$MNT/etc/$APP_NAME.env" ||
    fail "MOTOR_ARGS is not what the manifest renders to ($EXPECTED_ARGS)"
# shellcheck disable=SC2086  # deliberate split: one line per motor entry
MOTOR_COUNT="$(printf '%s\n' $MOTORS | wc -l)"
FOUND="$(grep -o -- '--motor ' "$MNT/etc/$APP_NAME.env" | wc -l)"
[ "$FOUND" = "$MOTOR_COUNT" ] ||
    fail "manifest declares $MOTOR_COUNT motors but the image configures $FOUND"
ok "all $MOTOR_COUNT motors configured in the image"

[ -x "$MNT/usr/local/sbin/$APP_NAME-firstboot" ] ||
    fail "the write-time configuration script is missing"
[ -x "$MNT/usr/local/lib/$APP_NAME/render-motor-args.sh" ] ||
    fail "the motor spec validator is missing, so firstboot cannot validate MOTORS"
[ -f "$MNT/etc/$APP_NAME-defaults.env" ] ||
    fail "firstboot has no defaults to fall back on"
grep -q '^PI_PASSWORD=' "$MNT/etc/$APP_NAME-defaults.env" &&
    fail "the build password was left in the image's defaults file"
ok "write-time configuration installed, with no password left behind"

FB="$MNT/etc/systemd/system/$APP_NAME-firstboot.service"
grep -q "^Before=NetworkManager.service $APP_NAME.service$" "$FB" ||
    fail "firstboot does not run before NetworkManager and the server"
ok "firstboot is ordered before both its consumers"

PROFILE="$MNT/etc/NetworkManager/system-connections/${ETH_IFACE}-static.nmconnection"
[ -f "$PROFILE" ] || fail "NetworkManager profile is missing"
[ "$(stat -c %a "$PROFILE")" = 600 ] || fail "NetworkManager profile is not mode 600"
grep -q "^interface-name=$ETH_IFACE$" "$PROFILE" || fail "profile targets the wrong interface"
grep -q "^address1=$ETH_ADDRESS/$ETH_PREFIX$" "$PROFILE" || fail "static address is wrong"
grep -q '^method=disabled$' "$PROFILE" || fail "IPv6 is not disabled"
if [ -n "${ETH_GATEWAY:-}" ]; then
    grep -q "^gateway=$ETH_GATEWAY$" "$PROFILE" || fail "gateway is wrong"
else
    grep -q '^never-default=true$' "$PROFILE" || fail "profile can install a default route"
    grep -Eq '^(gateway|dns)=' "$PROFILE" && fail "isolated profile contains a gateway or DNS"
    grep -q '^ignore-auto-dns=true$' "$PROFILE" || fail "profile can accept automatic DNS"
fi
grep -q '^no-auto-default=\*$' "$MNT/etc/NetworkManager/conf.d/00-no-auto-default.conf" ||
    fail "NetworkManager can create a competing DHCP profile"
ok "static network configuration"

grep -Eq '/boot/firmware[[:space:]]+vfat' "$MNT/etc/fstab" ||
    fail "boot partition mount does not match Raspberry Pi OS"
[ -f "$MNT/boot/firmware/cmdline.txt" ] || fail "cmdline.txt is missing"
ok "boot filesystem layout"

echo "FINAL IMAGE AUDIT PASSED"
