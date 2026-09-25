#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Exercise firstboot.sh against a fake root.
#
# This is the write-time configuration path: the flasher drops <app>.conf onto
# the card's FAT partition, and this script is what reads it on the Pi. It runs
# entirely off-device via FIRSTBOOT_ROOT, so what it proves is real rather than
# inspected:
#
#   * a card with no config keeps the baked defaults and exits 0;
#   * a card with a config gets exactly that address, hostname, port, motors;
#   * an isolated link gets no gateway and no DNS line at all;
#   * a gateway, when asked for, replaces never-default;
#   * an INVALID value changes nothing -- the instrument stays reachable;
#   * a password is applied once and scrubbed off the card;
#   * re-running is idempotent, because this runs on every boot.
# ---------------------------------------------------------------------------
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PI_IMAGE_DIR="$(cd "$HERE/.." && pwd)"

PASS=0
FAIL=0
ok()   { PASS=$((PASS + 1)); echo "  ok: $*"; }
bad()  { FAIL=$((FAIL + 1)); echo "  FAIL: $*" >&2; }
check() { if [ "$1" = 0 ]; then ok "$2"; else bad "$2"; fi; }

# shellcheck disable=SC1091
. "$PI_IMAGE_DIR/pi-app.env"

APP_NAME_LOCAL="$APP_NAME"

# --- build a fake root that looks like the finished image ------------------
make_root() {
    ROOT="$(mktemp -d)"
    mkdir -p "$ROOT/etc/NetworkManager/system-connections" \
             "$ROOT/boot/firmware" \
             "$ROOT/usr/local/lib/$APP_NAME_LOCAL" \
             "$ROOT/usr/local/sbin" \
             "$ROOT/home/$PI_USER"
    echo 'console=serial0,115200 root=PARTUUID=abc rootwait' > "$ROOT/boot/firmware/cmdline.txt"

    # What cscript.sh post-install leaves behind.
    grep -v '^PI_PASSWORD=' "$PI_IMAGE_DIR/pi-app.env" > "$ROOT/etc/${APP_NAME_LOCAL}-defaults.env"
    install -m 755 "$PI_IMAGE_DIR/render-motor-args.sh" \
        "$ROOT/usr/local/lib/$APP_NAME_LOCAL/render-motor-args.sh" 2>/dev/null \
        || cp "$PI_IMAGE_DIR/render-motor-args.sh" "$ROOT/usr/local/lib/$APP_NAME_LOCAL/render-motor-args.sh"
    chmod +x "$ROOT/usr/local/lib/$APP_NAME_LOCAL/render-motor-args.sh"
    # The baked fallbacks.
    printf 'PUMP_PORT=%s\nMOTOR_ARGS=%s\n' "$SERVER_PORT" \
        "$(bash "$PI_IMAGE_DIR/render-motor-args.sh" "$MOTORS")" \
        > "$ROOT/etc/${APP_NAME_LOCAL}.env"
    printf '%s\n' "$PI_HOSTNAME" > "$ROOT/etc/hostname"
    printf '127.0.0.1\tlocalhost\n127.0.1.1\t%s\n' "$PI_HOSTNAME" > "$ROOT/etc/hosts"

    # Installed under its app-derived name, which firstboot.sh relies on.
    cp "$PI_IMAGE_DIR/firstboot.sh" "$ROOT/usr/local/sbin/${APP_NAME_LOCAL}-firstboot"
    chmod +x "$ROOT/usr/local/sbin/${APP_NAME_LOCAL}-firstboot"
}

run_firstboot() {
    FIRSTBOOT_ROOT="$ROOT" bash "$ROOT/usr/local/sbin/${APP_NAME_LOCAL}-firstboot" \
        > "$ROOT/run.out" 2>&1
    echo $?
}

PROFILE_REL="etc/NetworkManager/system-connections/${ETH_IFACE}-static.nmconnection"

# =========================================================================
echo
echo "1. no config on the card -> baked defaults, clean exit"
make_root
RC="$(run_firstboot)"
check "$([ "$RC" = 0 ] && echo 0 || echo 1)" "exits 0 with no config file"
grep -q 'keeping the built-in defaults' "$ROOT/run.out" \
    && ok "says it is keeping the defaults" || bad "did not report using defaults"
# It must not invent a profile when it was given nothing to apply.
[ -f "$ROOT/$PROFILE_REL" ] && bad "wrote a profile with no config to act on" \
    || ok "left the image's own profile alone"
rm -rf "$ROOT"

# =========================================================================
echo
echo "2. a full config -> applied exactly"
make_root
cat > "$ROOT/boot/firmware/${APP_NAME_LOCAL}.conf" <<'CONF'
ETH_ADDRESS=192.168.44.9
ETH_PREFIX=25
ETH_GATEWAY=
ETH_DNS=
PI_HOSTNAME=pump-bench
SERVER_PORT=8080
MOTORS=x:22,23 y:5,6
CONF
RC="$(run_firstboot)"
check "$([ "$RC" = 0 ] && echo 0 || echo 1)" "exits 0"
grep -q '^address1=192\.168\.44\.9/25$' "$ROOT/$PROFILE_REL" \
    && ok "address and prefix applied" || { bad "address not applied"; cat "$ROOT/run.out"; }
grep -q '^interface-name='"$ETH_IFACE"'$' "$ROOT/$PROFILE_REL" \
    && ok "profile targets $ETH_IFACE" || bad "wrong interface"
grep -qx 'pump-bench' "$ROOT/etc/hostname" \
    && ok "hostname applied" || bad "hostname not applied"
grep -q '127\.0\.1\.1[[:space:]]*pump-bench' "$ROOT/etc/hosts" \
    && ok "/etc/hosts updated to match" || bad "/etc/hosts not updated"
grep -q '^PUMP_PORT=8080$' "$ROOT/etc/${APP_NAME_LOCAL}.env" \
    && ok "port applied" || bad "port not applied"
grep -q '^MOTOR_ARGS=--motor x:22,23,-1,-1,-1 --motor y:5,6,-1,-1,-1$' \
    "$ROOT/etc/${APP_NAME_LOCAL}.env" \
    && ok "motor set applied, with strapped mode pins" \
    || { bad "motor set not applied"; grep MOTOR_ARGS "$ROOT/etc/${APP_NAME_LOCAL}.env"; }
# The log has to land on the FAT partition: if the address is wrong the
# instrument is unreachable and the card is the only way to read what happened.
[ -f "$ROOT/boot/firmware/${APP_NAME_LOCAL}-firstboot.log" ] \
    && ok "log written to the boot partition" || bad "no log on the boot partition"
rm -rf "$ROOT"

# =========================================================================
echo
echo "3. isolated link -> no gateway, no DNS anywhere in the profile"
make_root
printf 'ETH_ADDRESS=192.168.10.5\nETH_PREFIX=24\nETH_GATEWAY=\nETH_DNS=\n' \
    > "$ROOT/boot/firmware/${APP_NAME_LOCAL}.conf"
run_firstboot >/dev/null
grep -q '^never-default=true$' "$ROOT/$PROFILE_REL" \
    && ok "never-default set" || bad "no never-default on an isolated link"
grep -q '^ignore-auto-dns=true$' "$ROOT/$PROFILE_REL" \
    && ok "ignore-auto-dns set" || bad "no ignore-auto-dns on an isolated link"
grep -Eq '^(gateway|dns)=' "$ROOT/$PROFILE_REL" \
    && bad "isolated profile contains a gateway or dns line" \
    || ok "no gateway and no dns line at all"
grep -q '^method=disabled$' "$ROOT/$PROFILE_REL" \
    && ok "IPv6 disabled" || bad "IPv6 not disabled"
rm -rf "$ROOT"

# =========================================================================
echo
echo "4. a routed LAN -> gateway replaces never-default"
make_root
cat > "$ROOT/boot/firmware/${APP_NAME_LOCAL}.conf" <<'CONF'
ETH_ADDRESS=10.194.22.184
ETH_PREFIX=24
ETH_GATEWAY=10.194.22.1
ETH_DNS=10.194.22.1
CONF
run_firstboot >/dev/null
grep -q '^gateway=10\.194\.22\.1$' "$ROOT/$PROFILE_REL" \
    && ok "gateway written" || bad "gateway not written"
grep -q '^dns=10\.194\.22\.1;$' "$ROOT/$PROFILE_REL" \
    && ok "dns written" || bad "dns not written"
grep -q '^never-default=true$' "$ROOT/$PROFILE_REL" \
    && bad "never-default left in place alongside a gateway" \
    || ok "never-default omitted when a gateway is set"
rm -rf "$ROOT"

# =========================================================================
echo
echo "5. invalid values -> nothing applied, previous config intact"
for badconf in \
    'ETH_ADDRESS=1.2.3' \
    'ETH_ADDRESS=10.0.0.1
ETH_PREFIX=99' \
    'ETH_ADDRESS=10.0.0.1
SERVER_PORT=70000' \
    'ETH_ADDRESS=10.0.0.1
PI_HOSTNAME=-nope-' \
    'ETH_ADDRESS=10.0.0.1
MOTORS=a:22,23 b:22,6' \
    'ETH_ADDRESS=10.0.0.1
ETH_GATEWAY=notanip' \
    ; do
    make_root
    printf '%s\n' "$badconf" > "$ROOT/boot/firmware/${APP_NAME_LOCAL}.conf"
    RC="$(run_firstboot)"
    label="$(printf '%s' "$badconf" | tr '\n' ' ')"
    if [ "$RC" = 0 ]; then
        bad "accepted an invalid config: $label"
    elif [ -f "$ROOT/$PROFILE_REL" ]; then
        bad "wrote a profile despite refusing the config: $label"
    elif ! grep -q '^PUMP_PORT='"$SERVER_PORT"'$' "$ROOT/etc/${APP_NAME_LOCAL}.env"; then
        bad "changed the port despite refusing the config: $label"
    else
        ok "refused and changed nothing: $label"
    fi
    rm -rf "$ROOT"
done

# A pin clash between the two motors is the one that would otherwise be silent:
# both motors would step together on the shared pin.
make_root
printf 'MOTORS=a:22,23 b:22,6\n' > "$ROOT/boot/firmware/${APP_NAME_LOCAL}.conf"
run_firstboot >/dev/null
grep -q 'more than one motor' "$ROOT/run.out" \
    && ok "names the pin clash in the log" || bad "pin clash not explained"
rm -rf "$ROOT"

# =========================================================================
echo
echo "6. password applied once, then scrubbed off the card"
make_root
{
    echo 'ETH_ADDRESS=10.0.0.7'
    printf 'PI_PASSWORD_B64=%s\n' "$(printf '%s' 'hunter2secret' | base64 | tr -d '\n')"
    echo 'PI_SSH_PUBKEY=ssh-ed25519 AAAATESTKEY test@example'
} > "$ROOT/boot/firmware/${APP_NAME_LOCAL}.conf"
run_firstboot >/dev/null
CONF_FILE="$ROOT/boot/firmware/${APP_NAME_LOCAL}.conf"
grep -q 'applied-and-removed' "$CONF_FILE" \
    && ok "password line scrubbed" || bad "password line not scrubbed"
# The point of the scrub: neither the plaintext nor its base64 may remain.
grep -q 'hunter2secret' "$CONF_FILE" \
    && bad "plaintext password still on the card" || ok "no plaintext password on the card"
grep -q "$(printf '%s' 'hunter2secret' | base64 | tr -d '\n')" "$CONF_FILE" \
    && bad "base64 password still on the card" || ok "no base64 password on the card"
# ...and it must not be sitting in the log either.
grep -q 'hunter2secret' "$ROOT/boot/firmware/${APP_NAME_LOCAL}-firstboot.log" \
    && bad "password leaked into the log" || ok "password not written to the log"
[ -f "$ROOT/home/$PI_USER/.ssh/authorized_keys" ] \
    && ok "authorised key installed" || bad "authorised key not installed"
grep -q 'AAAATESTKEY' "$ROOT/home/$PI_USER/.ssh/authorized_keys" \
    && ok "authorised key has the right contents" || bad "wrong key contents"
rm -rf "$ROOT"

# =========================================================================
echo
echo "7. idempotent -- it runs on every boot"
make_root
printf 'ETH_ADDRESS=172.16.5.5\nETH_PREFIX=16\nSERVER_PORT=9001\nMOTORS=solo:22,23\n' \
    > "$ROOT/boot/firmware/${APP_NAME_LOCAL}.conf"
run_firstboot >/dev/null
cp "$ROOT/$PROFILE_REL" "$ROOT/first.nmconnection"
cp "$ROOT/etc/${APP_NAME_LOCAL}.env" "$ROOT/first.env"
FIRST_HOST="$(cat "$ROOT/etc/hostname")"
RC="$(run_firstboot)"
check "$([ "$RC" = 0 ] && echo 0 || echo 1)" "second run also exits 0"
cmp -s "$ROOT/first.nmconnection" "$ROOT/$PROFILE_REL" \
    && ok "profile byte-identical on the second run" || bad "profile changed on re-run"
cmp -s "$ROOT/first.env" "$ROOT/etc/${APP_NAME_LOCAL}.env" \
    && ok "EnvironmentFile byte-identical on the second run" || bad "env changed on re-run"
[ "$FIRST_HOST" = "$(cat "$ROOT/etc/hostname")" ] \
    && ok "hostname stable on re-run" || bad "hostname changed on re-run"
# A single /etc/hosts entry, not one appended per boot.
[ "$(grep -c '127\.0\.1\.1' "$ROOT/etc/hosts")" = 1 ] \
    && ok "one 127.0.1.1 line, not one per boot" || bad "/etc/hosts grew on re-run"
rm -rf "$ROOT"

# =========================================================================
echo
echo "8. a Windows-written config (CRLF, quotes) is read correctly"
make_root
printf 'ETH_ADDRESS="10.9.9.9"\r\nETH_PREFIX=24\r\nSERVER_PORT=7000\r\n' \
    > "$ROOT/boot/firmware/${APP_NAME_LOCAL}.conf"
RC="$(run_firstboot)"
check "$([ "$RC" = 0 ] && echo 0 || echo 1)" "CRLF config accepted"
grep -q '^address1=10\.9\.9\.9/24$' "$ROOT/$PROFILE_REL" \
    && ok "CR and surrounding quotes stripped from the value" \
    || { bad "CRLF/quoted value mis-parsed"; grep address1 "$ROOT/$PROFILE_REL"; }
grep -q '^PUMP_PORT=7000$' "$ROOT/etc/${APP_NAME_LOCAL}.env" \
    && ok "port parsed from a CRLF file" || bad "port mis-parsed from CRLF"
rm -rf "$ROOT"

# =========================================================================
echo
echo "9. unknown keys are ignored, not executed"
make_root
{
    echo 'ETH_ADDRESS=10.1.1.1'
    echo 'SOMETHING_ELSE=whatever'
    # If this file were ever sourced instead of parsed, this would run as root.
    echo 'EVIL=$(touch '"$ROOT"'/pwned)'
} > "$ROOT/boot/firmware/${APP_NAME_LOCAL}.conf"
RC="$(run_firstboot)"
check "$([ "$RC" = 0 ] && echo 0 || echo 1)" "unknown keys do not fail the boot"
[ -e "$ROOT/pwned" ] \
    && bad "the config file was executed, not parsed" \
    || ok "config is parsed, never executed"
grep -q 'ignoring unrecognised key' "$ROOT/run.out" \
    && ok "unknown keys reported" || bad "unknown keys not reported"
rm -rf "$ROOT"

# =========================================================================
echo
echo "----------------------------------------"
if [ "$FAIL" -eq 0 ]; then
    echo "firstboot: $PASS checks passed"
    exit 0
fi
echo "firstboot: $FAIL of $((PASS + FAIL)) checks FAILED" >&2
exit 1
