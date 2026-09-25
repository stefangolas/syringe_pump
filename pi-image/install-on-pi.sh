#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Install this configuration onto a Pi that is ALREADY RUNNING, over SSH.
# Nothing is reflashed and the OS is left alone.
#
#   ssh chorylab@<pi>
#   cd ~/syringe_pump && git pull
#   sudo pi-image/install-on-pi.sh
#
# What it does:
#   * builds/refreshes the frozen venv from pi-image/server
#   * installs the systemd service, its EnvironmentFile and the write-time
#     config machinery, then starts the server
#
# What it does NOT do, unless you ask:
#   * change the network. You are reading this over SSH, and applying a static
#     address would drop that session and possibly strand the Pi. Use
#     --with-network only from a console, or when the address you are setting is
#     the one you are already connected on.
#
# Options:
#   --motors "<spec>"   motor set to run, e.g. "a:22,23,17,27,25 b:5,6,13,19,26"
#                       (default: whatever pi-app.env declares)
#   --one-motor         shorthand for just the first motor in pi-app.env
#   --port <n>          server port (default: pi-app.env's SERVER_PORT)
#   --with-network      ALSO apply the static address. Read the warning above.
#   --no-firstboot      skip the write-time config machinery
#   --dry-run           print what would happen, change nothing
# ---------------------------------------------------------------------------
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck disable=SC1091
. "$HERE/pi-app.env"

MOTORS_ARG=""
PORT_ARG=""
WITH_NETWORK=0
WITH_FIRSTBOOT=1
DRY_RUN=0
while [ $# -gt 0 ]; do
    case "$1" in
        --motors)       MOTORS_ARG="${2:-}"; shift 2 ;;
        --one-motor)    MOTORS_ARG="${MOTORS%% *}"; shift ;;
        --port)         PORT_ARG="${2:-}"; shift 2 ;;
        --with-network) WITH_NETWORK=1; shift ;;
        --no-firstboot) WITH_FIRSTBOOT=0; shift ;;
        --dry-run)      DRY_RUN=1; shift ;;
        -h|--help)      sed -n '2,30p' "$0"; exit 0 ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done

[ -n "$MOTORS_ARG" ] && MOTORS="$MOTORS_ARG"
[ -n "$PORT_ARG" ] && SERVER_PORT="$PORT_ARG"

say()  { echo ">> $*"; }
warn() { echo "!! $*" >&2; }
die()  { echo "ERROR: $*" >&2; exit 1; }

# Every mutating action goes through run(), so --dry-run is honest rather than
# a claim. A script that reconfigures a live instrument should be inspectable
# before it touches anything.
run() {
    if [ "$DRY_RUN" = 1 ]; then
        printf '   [dry-run] '; printf '%q ' "$@"; printf '\n'
    else
        "$@"
    fi
}
# For the handful of places that write a file rather than run a command.
write_file() {   # write_file <dest> <mode>   (content on stdin)
    local dest="$1" mode="$2" tmp
    if [ "$DRY_RUN" = 1 ]; then
        echo "   [dry-run] write $dest (mode $mode):"
        sed 's/^/        | /'
        return 0
    fi
    tmp="$(mktemp)"
    cat > "$tmp"
    chmod "$mode" "$tmp"
    mv -f "$tmp" "$dest"
}

[ "$DRY_RUN" = 1 ] || [ "$(id -u)" -eq 0 ] || die "run with sudo (or pass --dry-run)"

# --- adapt to the machine, rather than assume the manifest ----------------
# This Pi was set up by hand, so the checkout may not be where pi-app.env says
# and may not be owned by the user it names. Believe the filesystem.
REPO_DEST="$(cd "$HERE/.." && pwd)"
OWNER="$(stat -c %U "$REPO_DEST" 2>/dev/null || echo "")"
if [ -n "$OWNER" ] && [ "$OWNER" != root ] && [ "$OWNER" != "$PI_USER" ]; then
    say "repo is owned by '$OWNER', not '$PI_USER' -- using '$OWNER'"
    PI_USER="$OWNER"
fi
id -u "$PI_USER" >/dev/null 2>&1 || die "user '$PI_USER' does not exist on this Pi"

VENV="$REPO_DEST/.venv"
PROJECT="$REPO_DEST/$SERVER_PROJECT"
UNIT="/etc/systemd/system/${APP_NAME}.service"
FB_UNIT="/etc/systemd/system/${APP_NAME}-firstboot.service"

echo
echo "=== installing ${APP_NAME} onto this Pi ==="
echo "    repo      $REPO_DEST"
echo "    user      $PI_USER"
echo "    motors    $MOTORS"
echo "    port      $SERVER_PORT"
if [ "$WITH_NETWORK" = 1 ]; then
    echo "    network   WILL be set to ${ETH_ADDRESS}/${ETH_PREFIX} on ${ETH_IFACE}"
else
    echo "    network   left alone"
fi
[ "$DRY_RUN" = 1 ] && echo "    MODE      dry run, nothing will change"
echo

# --- sanity checks before touching anything ------------------------------
[ -f "$PROJECT/uv.lock" ] || die "$PROJECT/uv.lock is missing -- did 'git pull' run?"
[ -f "$REPO_DEST/syringe_pump/motor_server.py" ] || die "no syringe_pump/motor_server.py under $REPO_DEST"
grep -q 'parse_motor_spec' "$REPO_DEST/syringe_pump/motor_server.py" \
    || die "motor_server.py predates multi-motor support -- run 'git pull' first"

# Validate the motor set NOW, before the venv work, so a bad pinout costs
# seconds rather than a rebuilt environment.
MOTOR_ARGS="$("$HERE/render-motor-args.sh" "$MOTORS")" \
    || die "the motor set was rejected (see above)"
say "motor arguments: $MOTOR_ARGS"

# --- system packages ------------------------------------------------------
# Current Raspberry Pi OS ships python3-rpi-lgpio, a shim providing the
# RPi.GPIO API on top of lgpio because the original does not work on a Pi 5. It
# Conflicts with python3-rpi.gpio, so asking for both is never satisfiable.
NEED=""
for pkg in redis-server python3-venv; do
    dpkg -s "$pkg" >/dev/null 2>&1 || NEED="$NEED $pkg"
done
if dpkg -s python3-rpi-lgpio >/dev/null 2>&1; then
    say "python3-rpi-lgpio is installed; it provides RPi.GPIO"
elif ! dpkg -s python3-rpi.gpio >/dev/null 2>&1; then
    NEED="$NEED python3-rpi.gpio"
fi
if [ -n "$NEED" ]; then
    say "installing:$NEED"
    run env DEBIAN_FRONTEND=noninteractive apt-get update
    # shellcheck disable=SC2086  # deliberate split: one package per argument
    run env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends $NEED
else
    say "all required packages already installed"
fi
run systemctl enable --now redis-server

# --- uv, pinned -----------------------------------------------------------
UV="$(command -v uv || true)"
if [ -z "$UV" ] || ! uv --version 2>&1 | grep -q "$UV_VERSION"; then
    say "installing uv ${UV_VERSION}"
    run bash -c "curl -LsSf 'https://astral.sh/uv/${UV_VERSION}/install.sh' \
        | env UV_INSTALL_DIR=/usr/local/bin INSTALLER_NO_MODIFY_PATH=1 sh"
    UV=/usr/local/bin/uv
else
    say "uv $(uv --version) already present"
fi

# --- the venv -------------------------------------------------------------
# System interpreter with system site-packages, so apt's prebuilt RPi.GPIO
# stays importable. A uv-managed standalone Python would hide it.
say "building the frozen environment at $VENV"
run rm -rf "$VENV"
run "$UV" venv --python /usr/bin/python3 --system-site-packages "$VENV"
run env UV_PROJECT_ENVIRONMENT="$VENV" "$UV" sync \
    --project "$PROJECT" --frozen --no-dev --python /usr/bin/python3
run chown -R "${PI_USER}:${PI_USER}" "$VENV"

if [ "$DRY_RUN" = 0 ]; then
    # By spec for RPi.GPIO: importing it succeeds only on real Pi hardware, and
    # this IS real hardware, but keep the check identical to the image build's.
    PYTHON_IMPORTS="$PYTHON_IMPORTS" "$VENV/bin/python" - <<'PYCHECK'
import importlib
import importlib.util as u
import os
for name in os.environ["PYTHON_IMPORTS"].split(","):
    name = name.strip()
    if name:
        importlib.import_module(name)
        print("   import %s ok" % name)
assert u.find_spec("RPi.GPIO"), "RPi.GPIO is not visible in the venv"
print("   deps ok")
PYCHECK
fi

# --- write-time config machinery -----------------------------------------
if [ "$WITH_FIRSTBOOT" = 1 ]; then
    say "installing the write-time config machinery"
    run install -d -m 755 /usr/local/sbin "/usr/local/lib/${APP_NAME}"
    run install -m 755 "$HERE/firstboot.sh" "/usr/local/sbin/${APP_NAME}-firstboot"
    run install -m 755 "$HERE/render-motor-args.sh" \
        "/usr/local/lib/${APP_NAME}/render-motor-args.sh"
    # The runtime fallbacks, with the values this install actually used and
    # without the password.
    {
        grep -v -e '^PI_PASSWORD=' -e '^MOTORS=' -e '^SERVER_PORT=' -e '^REPO_DEST=' \
             -e '^PI_USER=' "$HERE/pi-app.env"
        printf 'MOTORS=%s\n' "'$MOTORS'"
        printf 'SERVER_PORT=%s\n' "$SERVER_PORT"
        printf 'REPO_DEST=%s\n' "$REPO_DEST"
        printf 'PI_USER=%s\n' "$PI_USER"
    } | write_file "/etc/${APP_NAME}-defaults.env" 644
    say "  firstboot does nothing until a ${APP_NAME}.conf exists on the boot"
    say "  partition, so installing it changes no current behaviour"
fi

# --- the service ----------------------------------------------------------
# Port and motor set go in the EnvironmentFile rather than being baked into
# ExecStart, so either can be changed later by editing one small file and
# restarting -- no unit rewrite, no daemon-reload.
{
    printf 'PUMP_PORT=%s\n' "$SERVER_PORT"
    printf 'MOTOR_ARGS=%s\n' "$MOTOR_ARGS"
} | write_file "/etc/${APP_NAME}.env" 644
say "wrote /etc/${APP_NAME}.env"

EXECSTART="${APP_EXEC//\$\{VENV\}/$VENV}"
EXECSTART="${EXECSTART//\$\{REPO_DEST\}/$REPO_DEST}"
EXECSTART="${EXECSTART//\$\{SERVER_PORT\}/$SERVER_PORT}"
case "$EXECSTART" in
    *'${'*) die "unsubstituted placeholder in APP_EXEC: $EXECSTART" ;;
esac

# Keep a copy of whatever was there before. This Pi was configured by hand, so
# the existing unit may be someone's deliberate work.
if [ -f "$UNIT" ] && [ "$DRY_RUN" = 0 ]; then
    cp -n "$UNIT" "${UNIT}.before-install" 2>/dev/null || true
    say "kept the previous unit as ${UNIT}.before-install"
fi

FB_AFTER=""
[ "$WITH_FIRSTBOOT" = 1 ] && FB_AFTER="
After=${APP_NAME}-firstboot.service"

write_file "$UNIT" 644 <<UNITFILE
[Unit]
Description=${APP_NAME} motor server
After=network.target ${SERVICE_REQUIRES}
Requires=${SERVICE_REQUIRES}${FB_AFTER}

[Service]
Type=simple
User=${PI_USER}
Group=${PI_USER}
SupplementaryGroups=gpio dialout
WorkingDirectory=${REPO_DEST}
Environment=PYTHONUNBUFFERED=1
EnvironmentFile=/etc/${APP_NAME}.env
ExecStart=${EXECSTART}

# The pump is a physical device: if the server dies, bring it straight back
# rather than leaving the motors unreachable.
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
UNITFILE
say "wrote $UNIT"

if [ "$WITH_FIRSTBOOT" = 1 ]; then
    write_file "$FB_UNIT" 644 <<UNITFILE
[Unit]
Description=Apply ${APP_NAME} settings from the boot partition
After=local-fs.target
Requires=local-fs.target
Before=NetworkManager.service ${APP_NAME}.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/${APP_NAME}-firstboot
StandardOutput=journal+console
StandardError=journal+console

[Install]
WantedBy=multi-user.target
UNITFILE
    say "wrote $FB_UNIT"
fi

# The account must be able to reach the GPIO character device.
for grp in gpio dialout; do
    getent group "$grp" >/dev/null 2>&1 && run usermod -aG "$grp" "$PI_USER"
done

# Something may already be holding the port -- a hand-started server in a
# screen session, most likely. systemd cannot take a port that is in use, and
# the failure message for that is unhelpful, so say it plainly here.
if [ "$DRY_RUN" = 0 ] && command -v ss >/dev/null 2>&1; then
    if ss -ltnp 2>/dev/null | grep -q ":${SERVER_PORT} "; then
        if ! systemctl is-active --quiet "${APP_NAME}.service"; then
            warn "something is already listening on port ${SERVER_PORT} and it is"
            warn "not this service. Stop it (a hand-started motor_server.py in a"
            warn "screen/tmux session, or an old unit) or the service cannot bind."
        fi
    fi
fi

run systemctl daemon-reload
[ "$WITH_FIRSTBOOT" = 1 ] && run systemctl enable "${APP_NAME}-firstboot.service"
run systemctl enable "${APP_NAME}.service"
run systemctl restart "${APP_NAME}.service"

# --- the network, only if asked ------------------------------------------
if [ "$WITH_NETWORK" = 1 ]; then
    warn "applying the static address ${ETH_ADDRESS}/${ETH_PREFIX} to ${ETH_IFACE}"
    warn "if you are connected over that interface on a different address, this"
    warn "session will drop"
    NMDIR=/etc/NetworkManager/system-connections
    run install -d -m 700 "$NMDIR"
    {
        printf '[connection]\n'
        printf 'id=%s-static\n' "$ETH_IFACE"
        printf 'type=ethernet\n'
        printf 'interface-name=%s\n' "$ETH_IFACE"
        printf 'autoconnect=true\n'
        printf 'autoconnect-priority=100\n'
        printf '\n[ipv4]\n'
        printf 'method=manual\n'
        printf 'address1=%s/%s\n' "$ETH_ADDRESS" "$ETH_PREFIX"
        if [ -n "${ETH_GATEWAY:-}" ]; then
            printf 'gateway=%s\n' "$ETH_GATEWAY"
        else
            printf 'never-default=true\n'
        fi
        if [ -n "${ETH_DNS:-}" ]; then
            printf 'dns=%s;\n' "$ETH_DNS"
        else
            printf 'ignore-auto-dns=true\n'
        fi
        printf 'may-fail=false\n'
        printf '\n[ipv6]\n'
        printf 'method=disabled\n'
    } | write_file "$NMDIR/${ETH_IFACE}-static.nmconnection" 600
    say "wrote the profile; it takes effect on reboot, or:"
    say "  sudo nmcli connection reload && sudo nmcli connection up ${ETH_IFACE}-static"
else
    say "network untouched (pass --with-network to change it)"
fi

echo
if [ "$DRY_RUN" = 1 ]; then
    echo "Dry run complete. Nothing was changed."
    exit 0
fi

echo "Done. Check it:"
echo "  systemctl status ${APP_NAME} --no-pager"
echo "  journalctl -u ${APP_NAME} -n 40 --no-pager"
echo "  curl -s http://127.0.0.1:${SERVER_PORT}/motors"
echo
echo "Motors now configured: ${MOTORS}"
echo "  run:  curl -X POST http://127.0.0.1:${SERVER_PORT}/motor/a/run \\"
echo "             -H 'Content-Type: application/json' -d '{\"steps\": 200}'"
echo "  stop: curl -X POST http://127.0.0.1:${SERVER_PORT}/motor/a/stop"
echo
echo "To change the port or the motor set later, edit /etc/${APP_NAME}.env and"
echo "  sudo systemctl restart ${APP_NAME}"
