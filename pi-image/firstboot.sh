#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Apply the card's own settings, from the FAT boot partition.
#
# Installed as /usr/local/sbin/<app>-firstboot and run by
# <app>-firstboot.service on EVERY boot, before NetworkManager and before the
# server. Its whole job is to let one baked image serve every instrument: the
# flasher writes <app>.conf onto the boot partition, and this reads it.
#
# Why the boot partition: it is FAT, so Windows can mount and edit it. Nothing
# here may depend on writing the ext4 root from another machine, because that
# is exactly what a Windows flashing host cannot do.
#
# Why every boot rather than once: re-addressing an instrument then means
# editing one text file on a partition any laptop can mount, and rebooting.
# Every action below is idempotent. The password is the one exception -- it is
# applied and then scrubbed from the card, because a plaintext password must
# not sit on a FAT partition indefinitely.
#
# With no config file on the card, the values baked in at build time stand and
# this exits cleanly. That is the intended path for a card nobody customised.
# ---------------------------------------------------------------------------
set -uo pipefail

# The app name comes from our own filename, so this script stays identical
# between instruments -- it is installed as <app>-firstboot by cscript.sh.
SELF="$(basename "$0")"
APP_NAME="${SELF%-firstboot}"

# Everything below is addressed through $R, so this can be run against a fake
# root and tested off the device. Empty in production, which is the only value
# the installed unit ever passes -- the same trick as sdm's own $SDMPT.
R="${FIRSTBOOT_ROOT:-}"

DEFAULTS="$R/etc/${APP_NAME}-defaults.env"
RENDER="$R/usr/local/lib/${APP_NAME}/render-motor-args.sh"

# Bookworm+ mounts the FAT partition at /boot/firmware, earlier at /boot.
BOOTDIR=""
for d in "$R/boot/firmware" "$R/boot"; do
    if [ -d "$d" ] && [ -f "$d/cmdline.txt" ]; then BOOTDIR="$d"; break; fi
done

LOG=/dev/null
[ -n "$BOOTDIR" ] && LOG="$BOOTDIR/${APP_NAME}-firstboot.log"
# Log to the card as well as the journal: if the network settings are wrong the
# instrument is unreachable, and then the only way to read what happened is to
# put the card back in a laptop.
exec > >(tee -a "$LOG") 2>&1
# Flush on every exit path. A bad boot is precisely when the log matters most,
# and precisely when the Pi is most likely to be switched off before the
# kernel's writeback timer fires.
trap 'sync' EXIT

echo "=== ${APP_NAME} firstboot $(date -u) ==="

if [ ! -f "$DEFAULTS" ]; then
    echo "ERROR: $DEFAULTS is missing; the image was not built correctly." >&2
    exit 1
fi
# shellcheck disable=SC1090
. "$DEFAULTS"

CONF=""
[ -n "$BOOTDIR" ] && [ -f "$BOOTDIR/${APP_NAME}.conf" ] && CONF="$BOOTDIR/${APP_NAME}.conf"
if [ -z "$CONF" ]; then
    echo "no ${APP_NAME}.conf on the boot partition; keeping the built-in defaults:"
    echo "  address ${ETH_ADDRESS}/${ETH_PREFIX} on ${ETH_IFACE}, port ${SERVER_PORT}"
    echo "  motors  ${MOTORS}"
    exit 0
fi

echo "reading $CONF"

# --- read the card's config ----------------------------------------------
# Parsed key by key rather than sourced: this file is written by a flasher on
# someone's laptop and lives on a removable partition, so it is the least
# trustworthy input in the system. Sourcing it would execute it as root.
# Only these keys are recognised, and each value is validated below.
CFG_ETH_ADDRESS=""; CFG_ETH_PREFIX=""; CFG_ETH_GATEWAY=""; CFG_ETH_DNS=""
CFG_PI_HOSTNAME=""; CFG_SERVER_PORT=""; CFG_MOTORS=""
CFG_PI_PASSWORD_B64=""; CFG_PI_SSH_PUBKEY=""

while IFS= read -r line || [ -n "$line" ]; do
    line="${line%$'\r'}"                      # a Windows flasher may leave CR
    case "$line" in ''|'#'*) continue ;; esac
    case "$line" in *=*) ;; *) continue ;; esac
    key="${line%%=*}"
    val="${line#*=}"
    # Strip one layer of surrounding quotes, which a hand-edit may well add.
    case "$val" in
        \"*\") val="${val#\"}"; val="${val%\"}" ;;
        \'*\') val="${val#\'}"; val="${val%\'}" ;;
    esac
    case "$key" in
        ETH_ADDRESS)     CFG_ETH_ADDRESS="$val" ;;
        ETH_PREFIX)      CFG_ETH_PREFIX="$val" ;;
        ETH_GATEWAY)     CFG_ETH_GATEWAY="$val" ;;
        ETH_DNS)         CFG_ETH_DNS="$val" ;;
        PI_HOSTNAME)     CFG_PI_HOSTNAME="$val" ;;
        SERVER_PORT)     CFG_SERVER_PORT="$val" ;;
        MOTORS)          CFG_MOTORS="$val" ;;
        PI_PASSWORD_B64) CFG_PI_PASSWORD_B64="$val" ;;
        PI_SSH_PUBKEY)   CFG_PI_SSH_PUBKEY="$val" ;;
        *) echo "  ignoring unrecognised key: $key" ;;
    esac
done < "$CONF"

# --- validate BEFORE changing anything -----------------------------------
# A half-applied config is worse than none: a bad address with a good hostname
# leaves an instrument that is named correctly and unreachable. Everything is
# checked first, and a failure leaves the previous settings entirely intact.
ERRORS=0
bad() { echo "  INVALID: $*" >&2; ERRORS=$((ERRORS + 1)); }

is_ipv4() {
    local ip="$1" o1 o2 o3 o4
    case "$ip" in
        *.*.*.*) ;;
        *) return 1 ;;
    esac
    IFS=. read -r o1 o2 o3 o4 <<EOF
$ip
EOF
    for o in "$o1" "$o2" "$o3" "$o4"; do
        case "$o" in
            ''|*[!0-9]*) return 1 ;;
        esac
        [ "$o" -le 255 ] || return 1
    done
    return 0
}

if [ -n "$CFG_ETH_ADDRESS" ]; then
    is_ipv4 "$CFG_ETH_ADDRESS" || bad "ETH_ADDRESS='$CFG_ETH_ADDRESS' is not an IPv4 address"
fi
if [ -n "$CFG_ETH_PREFIX" ]; then
    case "$CFG_ETH_PREFIX" in
        ''|*[!0-9]*) bad "ETH_PREFIX='$CFG_ETH_PREFIX' is not a number" ;;
        *) { [ "$CFG_ETH_PREFIX" -ge 1 ] && [ "$CFG_ETH_PREFIX" -le 32 ]; } \
               || bad "ETH_PREFIX='$CFG_ETH_PREFIX' is outside 1-32" ;;
    esac
fi
if [ -n "$CFG_ETH_GATEWAY" ]; then
    is_ipv4 "$CFG_ETH_GATEWAY" || bad "ETH_GATEWAY='$CFG_ETH_GATEWAY' is not an IPv4 address"
fi
if [ -n "$CFG_ETH_DNS" ]; then
    # shellcheck disable=SC2086  # deliberate split: DNS may be a ;-separated list
    for d in ${CFG_ETH_DNS//;/ }; do
        is_ipv4 "$d" || bad "ETH_DNS entry '$d' is not an IPv4 address"
    done
fi
if [ -n "$CFG_SERVER_PORT" ]; then
    case "$CFG_SERVER_PORT" in
        ''|*[!0-9]*) bad "SERVER_PORT='$CFG_SERVER_PORT' is not a number" ;;
        *) { [ "$CFG_SERVER_PORT" -ge 1 ] && [ "$CFG_SERVER_PORT" -le 65535 ]; } \
               || bad "SERVER_PORT='$CFG_SERVER_PORT' is outside 1-65535" ;;
    esac
fi
if [ -n "$CFG_PI_HOSTNAME" ]; then
    # RFC 1123: letters, digits and hyphens, not starting or ending with one.
    case "$CFG_PI_HOSTNAME" in
        -*|*-) bad "PI_HOSTNAME='$CFG_PI_HOSTNAME' may not start or end with '-'" ;;
        *[!a-zA-Z0-9-]*) bad "PI_HOSTNAME='$CFG_PI_HOSTNAME' has characters outside a-z 0-9 -" ;;
        *) [ "${#CFG_PI_HOSTNAME}" -le 63 ] \
               || bad "PI_HOSTNAME='$CFG_PI_HOSTNAME' is longer than 63 characters" ;;
    esac
fi
MOTOR_ARGS_NEW=""
if [ -n "$CFG_MOTORS" ]; then
    if [ -x "$RENDER" ]; then
        # The renderer is the single source of truth for what a valid motor
        # spec is, and it is the same script the image build used.
        if ! MOTOR_ARGS_NEW="$("$RENDER" "$CFG_MOTORS" 2>&1)"; then
            bad "MOTORS='$CFG_MOTORS': $MOTOR_ARGS_NEW"
            MOTOR_ARGS_NEW=""
        fi
    else
        bad "cannot validate MOTORS: $RENDER is missing"
    fi
fi

if [ "$ERRORS" -gt 0 ]; then
    echo >&2
    echo "REFUSING to apply $ERRORS invalid setting(s). Nothing was changed, so the" >&2
    echo "instrument is still reachable on its previous configuration:" >&2
    echo "  address ${ETH_ADDRESS}/${ETH_PREFIX} on ${ETH_IFACE}, port ${SERVER_PORT}" >&2
    echo "Fix ${APP_NAME}.conf on the boot partition and reboot." >&2
    exit 1
fi

# --- apply ----------------------------------------------------------------
ADDRESS="${CFG_ETH_ADDRESS:-$ETH_ADDRESS}"
PREFIX="${CFG_ETH_PREFIX:-$ETH_PREFIX}"
# An explicitly EMPTY gateway in the config file means "isolated link", and
# must override a non-empty baked default. That is why these two read the
# config key's presence rather than falling back with :-.
if grep -q '^[[:space:]]*ETH_GATEWAY=' "$CONF" 2>/dev/null; then
    GATEWAY="$CFG_ETH_GATEWAY"
else
    GATEWAY="${ETH_GATEWAY:-}"
fi
if grep -q '^[[:space:]]*ETH_DNS=' "$CONF" 2>/dev/null; then
    DNS="$CFG_ETH_DNS"
else
    DNS="${ETH_DNS:-}"
fi
HOSTNAME_NEW="${CFG_PI_HOSTNAME:-$PI_HOSTNAME}"
PORT="${CFG_SERVER_PORT:-$SERVER_PORT}"
if [ -n "$MOTOR_ARGS_NEW" ]; then
    MOTOR_ARGS="$MOTOR_ARGS_NEW"
    MOTORS_APPLIED="$CFG_MOTORS"
else
    MOTOR_ARGS="$("$RENDER" "$MOTORS")"
    MOTORS_APPLIED="$MOTORS"
fi

echo "applying:"
echo "  address  ${ADDRESS}/${PREFIX} on ${ETH_IFACE}"
echo "  gateway  ${GATEWAY:-<none, isolated link>}"
echo "  dns      ${DNS:-<none, isolated link>}"
echo "  hostname ${HOSTNAME_NEW}"
echo "  port     ${PORT}"
echo "  motors   ${MOTORS_APPLIED}"

# --- network profile ------------------------------------------------------
# Byte-identical to what build.sh bakes, from the same inputs. Written to a
# temp file and moved into place so NetworkManager never sees a partial one.
NMDIR="$R/etc/NetworkManager/system-connections"
PROFILE="$NMDIR/${ETH_IFACE}-static.nmconnection"
install -d -m 700 "$NMDIR"
TMP="$(mktemp)"
{
    printf '[connection]\n'
    printf 'id=%s-static\n' "$ETH_IFACE"
    printf 'type=ethernet\n'
    printf 'interface-name=%s\n' "$ETH_IFACE"
    printf 'autoconnect=true\n'
    printf 'autoconnect-priority=100\n'
    printf '\n[ipv4]\n'
    printf 'method=manual\n'
    printf 'address1=%s/%s\n' "$ADDRESS" "$PREFIX"
    if [ -n "$GATEWAY" ]; then
        printf 'gateway=%s\n' "$GATEWAY"
    else
        # No default route through this interface: the Pi then cannot reach,
        # and cannot be reached from, anything but hosts on the same switch.
        printf 'never-default=true\n'
    fi
    if [ -n "$DNS" ]; then
        printf 'dns=%s;\n' "$DNS"
    else
        printf 'ignore-auto-dns=true\n'
    fi
    printf 'may-fail=false\n'
    printf '\n[ipv6]\n'
    printf 'method=disabled\n'
} > "$TMP"
chmod 600 "$TMP"
mv -f "$TMP" "$PROFILE"
# NetworkManager silently ignores a keyfile that is group- or world-readable.
chmod 600 "$PROFILE"
echo "  wrote $PROFILE"

# --- hostname -------------------------------------------------------------
# /etc/hostname directly rather than hostnamectl: this runs before dbus is up.
CURRENT_HOST="$(cat "$R/etc/hostname" 2>/dev/null | tr -d '[:space:]')"
if [ "$CURRENT_HOST" != "$HOSTNAME_NEW" ]; then
    printf '%s\n' "$HOSTNAME_NEW" > "$R/etc/hostname"
    if [ -n "$CURRENT_HOST" ] && grep -q "$CURRENT_HOST" "$R/etc/hosts" 2>/dev/null; then
        sed -i "s/\(127\.0\.1\.1[[:space:]]*\).*/\1${HOSTNAME_NEW}/" "$R/etc/hosts"
    else
        grep -q '^127\.0\.1\.1' "$R/etc/hosts" 2>/dev/null \
            || printf '127.0.1.1\t%s\n' "$HOSTNAME_NEW" >> "$R/etc/hosts"
    fi
    echo "  hostname ${CURRENT_HOST:-<unset>} -> ${HOSTNAME_NEW}"
fi

# --- runtime settings the service reads ----------------------------------
# The unit has EnvironmentFile=/etc/<app>.env and leaves $PUMP_PORT and
# $MOTOR_ARGS for systemd to expand, so rewriting this file is all it takes to
# change the port or the motor set. No unit is regenerated and no daemon-reload
# is needed, because the unit itself never changes.
TMP="$(mktemp)"
{
    printf 'PUMP_PORT=%s\n' "$PORT"
    printf 'MOTOR_ARGS=%s\n' "$MOTOR_ARGS"
} > "$TMP"
chmod 644 "$TMP"
mv -f "$TMP" "$R/etc/${APP_NAME}.env"
echo "  wrote /etc/${APP_NAME}.env"

# --- credentials ----------------------------------------------------------
if [ -n "$CFG_PI_SSH_PUBKEY" ]; then
    KEYDIR="$R/home/${PI_USER}/.ssh"
    install -d -m 700 "$KEYDIR"
    printf '%s\n' "$CFG_PI_SSH_PUBKEY" > "$KEYDIR/authorized_keys"
    chmod 600 "$KEYDIR/authorized_keys"
    # No chown against a fake root: the account does not exist there.
    [ -z "$R" ] && chown -R "${PI_USER}:${PI_USER}" "$KEYDIR"
    echo "  installed the authorised key for ${PI_USER}"
fi

# chpasswd edits the real /etc/shadow, so it is skipped against a fake root.
# The scrub is still exercised, because a plaintext password left on a FAT
# partition is the failure that actually matters here.
if [ -n "$CFG_PI_PASSWORD_B64" ] && [ -n "$R" ]; then
    echo "  [test root] skipping chpasswd; scrubbing the card as production does"
    sed -i 's/^\([[:space:]]*PI_PASSWORD_B64=\).*/\1<applied-and-removed>/' "$CONF"
elif [ -n "$CFG_PI_PASSWORD_B64" ]; then
    # Base64 because this file is written by PowerShell and read by bash, and
    # any quoting scheme that survives one can break the other. It is encoding,
    # not encryption, so it gets scrubbed just as thoroughly below.
    if PW="$(printf '%s' "$CFG_PI_PASSWORD_B64" | base64 -d 2>/dev/null)" && [ -n "$PW" ]; then
        if printf '%s:%s\n' "$PI_USER" "$PW" | chpasswd; then
            echo "  set the password for ${PI_USER}"
            # Scrub it from the card. A FAT partition is readable by anyone who
            # picks the card up, and this is the device's SSH login.
            sed -i 's/^\([[:space:]]*PI_PASSWORD_B64=\).*/\1<applied-and-removed>/' "$CONF"
            sync
            echo "  removed the password from $CONF"
        else
            echo "  WARNING: chpasswd failed; the previous password still applies" >&2
        fi
        unset PW
    else
        echo "  WARNING: PI_PASSWORD_B64 is not valid base64; ignoring it" >&2
    fi
fi

echo "=== firstboot complete ==="
exit 0
