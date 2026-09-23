#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Run cscript.sh phase 0 against a fake mounted image.
#
# Phase 0 is the only phase that can be exercised off a Pi: it runs on the
# host and just moves files around. It is also where the expensive bugs have
# been -- shellcheck cannot see that a path resolves to nothing, so the only
# way to catch it is to run it.
#
# The script is deliberately copied somewhere ELSE before being run, because
# that is what sdm does: it installs the cscript into the image and invokes
# it from there. Anything the script expects to find beside itself is gone by
# then. That exact assumption failed a build once.
# ---------------------------------------------------------------------------
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PI_IMAGE_DIR="$(cd "$HERE/.." && pwd)"
REPO_ROOT="$(cd "$PI_IMAGE_DIR/.." && pwd)"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "ok: $*"; }

# Git Bash on Windows cannot apply POSIX modes, and phase 0 installs files
# with explicit ones. Skip rather than report a failure that says nothing
# about the script -- CI runs this on Linux, where it is meaningful.
probe="$TMP/probe"
mkdir -p "$probe"
if ! install -d -m 700 "$probe/d" 2>/dev/null || [ "$(stat -c %a "$probe/d")" != 700 ]; then
    echo "SKIP: this filesystem does not honour POSIX modes"
    exit 0
fi

# shellcheck disable=SC1091
. "$PI_IMAGE_DIR/pi-app.env"

# --- a staging directory, as build.sh renders it --------------------------
BUILD="$TMP/build"
mkdir -p "$BUILD"
grep -v '^PI_PASSWORD=' "$PI_IMAGE_DIR/pi-app.env" > "$BUILD/pi-app.env"
printf 'PI_PASSWORD=%s\n' 'test-password' >> "$BUILD/pi-app.env"
printf '[connection]\nid=%s-static\n' "$ETH_IFACE" > "$BUILD/${ETH_IFACE}-static.nmconnection"
printf '[Unit]\nDescription=%s\n' "$APP_NAME" > "$BUILD/${APP_NAME}.service"
printf '[Unit]\nDescription=%s firstboot\n' "$APP_NAME" > "$BUILD/${APP_NAME}-firstboot.service"
printf 'PUMP_PORT=%s\nMOTOR_ARGS=%s\n' "$SERVER_PORT" \
    "$(bash "$PI_IMAGE_DIR/render-motor-args.sh" "$MOTORS")" > "$BUILD/${APP_NAME}.env"
install -m 755 "$PI_IMAGE_DIR/firstboot.sh"         "$BUILD/firstboot.sh"
install -m 755 "$PI_IMAGE_DIR/render-motor-args.sh" "$BUILD/render-motor-args.sh"

# --- a fake mounted image -------------------------------------------------
# Only directories a real Raspberry Pi OS image actually ships, so the test
# cannot pass by handing phase 0 something the Pi will not have.
SDMPT="$TMP/img"
mkdir -p "$SDMPT/etc/systemd/system" "$SDMPT/usr/local/sdm" "$SDMPT/home"

# --- sdm copies the cscript into the image and runs it from there ---------
install -m 755 "$PI_IMAGE_DIR/cscript.sh" "$SDMPT/usr/local/sdm/cscript.sh"

(
    export SDMPT PI_IMAGE_REPO="$REPO_ROOT" PI_IMAGE_BUILD="$BUILD"
    bash "$SDMPT/usr/local/sdm/cscript.sh" 0
)

# --- what phase 0 must have left behind -----------------------------------
[ -f "$SDMPT/etc/pi-image-app.env" ] \
    || fail "manifest was not carried into the image"
grep -q '^PI_PASSWORD=test-password$' "$SDMPT/etc/pi-image-app.env" \
    || fail "the manifest in the image is not the one build.sh rendered"
ok "manifest staged for post-install"

for f in syringe_pump/motor_server.py syringe_pump/A4988.py syringe_pump/syringe.py \
         syringe_pump/curl_requests.py pyproject.toml; do
    [ -e "$SDMPT$REPO_DEST/$f" ] || fail "repo is missing $f"
done
ok "application unpacked at $REPO_DEST"

# The frozen environment lives under an excluded directory, so it is copied
# back in explicitly. If that ever regresses, post-install's uv sync fails on
# the build machine instead of the instrument -- but only if this is checked.
[ -f "$SDMPT$REPO_DEST/$SERVER_PROJECT/uv.lock" ] \
    || fail "$SERVER_PROJECT/uv.lock did not reach the image"
[ -f "$SDMPT$REPO_DEST/$SERVER_PROJECT/pyproject.toml" ] \
    || fail "$SERVER_PROJECT/pyproject.toml did not reach the image"
ok "frozen server environment present at $SERVER_PROJECT"

for excluded in .git build syringe_pump.egg-info dump.rdb; do
    [ -e "$SDMPT$REPO_DEST/$excluded" ] \
        && fail "$excluded should not be in the image"
done
# pi-image itself is excluded, so only the server project may survive from it.
for stray in pi-image/build.sh pi-image/cscript.sh pi-image/tests; do
    [ -e "$SDMPT$REPO_DEST/$stray" ] \
        && fail "$stray is build-time tooling and should not be in the image"
done
ok "build-time-only paths excluded"

[ -f "$SDMPT/etc/NetworkManager/system-connections/${ETH_IFACE}-static.nmconnection" ] \
    || fail "the network profile was not installed"
[ "$(stat -c %a "$SDMPT/etc/NetworkManager/system-connections/${ETH_IFACE}-static.nmconnection")" = 600 ] \
    || fail "NetworkManager ignores a connection profile that is not mode 600"
ok "static ethernet profile installed, mode 600"

[ -f "$SDMPT/etc/systemd/system/${APP_NAME}.service" ] \
    || fail "the service unit was not installed"
[ -f "$SDMPT/etc/systemd/system/${APP_NAME}-firstboot.service" ] \
    || fail "the firstboot unit was not installed"
ok "both units installed"

# --- write-time configuration machinery ----------------------------------
[ -x "$SDMPT/usr/local/sbin/${APP_NAME}-firstboot" ] \
    || fail "firstboot is not installed as an executable"
# It derives the app name from its own filename, so the name it is installed
# under is load-bearing rather than cosmetic.
grep -q 'APP_NAME="${SELF%-firstboot}"' "$SDMPT/usr/local/sbin/${APP_NAME}-firstboot" \
    || fail "firstboot no longer derives its app name from its filename"
[ -x "$SDMPT/usr/local/lib/${APP_NAME}/render-motor-args.sh" ] \
    || fail "the motor spec validator was not installed"
[ -f "$SDMPT/etc/${APP_NAME}-defaults.env" ] \
    || fail "firstboot has no defaults to fall back on"
grep -q '^PI_PASSWORD=' "$SDMPT/etc/${APP_NAME}-defaults.env" \
    && fail "the password must not be left in the image's defaults file"
grep -q "^MOTORS=" "$SDMPT/etc/${APP_NAME}-defaults.env" \
    || fail "the defaults file carries no MOTORS, so firstboot cannot fall back"
ok "write-time configuration installed, without the password"

[ -f "$SDMPT/etc/${APP_NAME}.env" ] \
    || fail "the service's EnvironmentFile was not installed"
grep -q "^PUMP_PORT=${SERVER_PORT}$" "$SDMPT/etc/${APP_NAME}.env" \
    || fail "EnvironmentFile does not carry the port"
grep -q '^MOTOR_ARGS=--motor ' "$SDMPT/etc/${APP_NAME}.env" \
    || fail "EnvironmentFile does not carry rendered motor arguments"
ok "runtime EnvironmentFile installed"

# The account does not exist until sdm's user plugin runs in phase 1, so
# phase 0 must not create anything it would have to own.
[ -e "$SDMPT/home/${PI_USER}/.ssh" ] \
    && fail "phase 0 wrote into a home directory that has no owner yet"
ok "no ownerless files under the home directory"

# --- and it must fail loudly, not silently, without its staging dir -------
if (
    export SDMPT PI_IMAGE_REPO="$REPO_ROOT"
    unset PI_IMAGE_BUILD
    bash "$SDMPT/usr/local/sdm/cscript.sh" 0 >/dev/null 2>&1
); then
    fail "phase 0 succeeded with no PI_IMAGE_BUILD; it cannot have staged anything"
fi
ok "missing staging directory is a hard error"

echo "phase 0 ok"
