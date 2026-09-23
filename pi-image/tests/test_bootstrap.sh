#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Check the flashers against the manifest, and the README against the flashers.
#
# The flashers are fetched standalone with curl|bash and irm|iex, so they cannot
# read pi-app.env -- they carry their own copies of the defaults. That
# duplication is unavoidable and it is exactly the kind that rots silently: the
# manifest gets a new address, the image is rebuilt, and the flasher keeps
# telling people to reach the Pi at the old one. This is the guard.
# ---------------------------------------------------------------------------
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PI_IMAGE_DIR="$(cd "$HERE/.." && pwd)"
ROOT="$(cd "$PI_IMAGE_DIR/.." && pwd)"
README="$ROOT/README.md"
SH="$PI_IMAGE_DIR/bootstrap.sh"
PS1F="$PI_IMAGE_DIR/bootstrap.ps1"

FAILED=0
fail() { echo "FAIL: $*" >&2; FAILED=1; }
ok()   { echo "ok: $*"; }

# shellcheck disable=SC1091
. "$PI_IMAGE_DIR/pi-app.env"

# --- the flashers' defaults must equal the manifest's --------------------
# bootstrap.sh keeps them as D_<KEY>; bootstrap.ps1 in a $Defaults hashtable.
check_default() {   # check_default <key> <expected>
    local key="$1" want="$2" got_sh got_ps
    got_sh="$(sed -n "s/^D_${key}=\"\(.*\)\"$/\1/p" "$SH" | head -1)"
    got_ps="$(sed -n "s/^[[:space:]]*${key} *= *'\(.*\)'$/\1/p" "$PS1F" | head -1)"
    if [ "$got_sh" != "$want" ]; then
        fail "bootstrap.sh D_${key}='${got_sh}' but pi-app.env says '${want}'"
    elif [ "$got_ps" != "$want" ]; then
        fail "bootstrap.ps1 ${key}='${got_ps}' but pi-app.env says '${want}'"
    else
        ok "${key} matches the manifest in both flashers ('${want}')"
    fi
}

check_default ETH_ADDRESS "$ETH_ADDRESS"
check_default ETH_PREFIX  "$ETH_PREFIX"
check_default ETH_GATEWAY "${ETH_GATEWAY:-}"
check_default ETH_DNS     "${ETH_DNS:-}"
check_default PI_HOSTNAME "$PI_HOSTNAME"
check_default PI_USER     "$PI_USER"
check_default SERVER_PORT "$SERVER_PORT"
check_default MOTORS      "$MOTORS"

# The single-motor spec must be the manifest's FIRST entry, unchanged --
# otherwise choosing "1 motor" at the prompt silently rewires the pump.
FIRST_MOTOR="${MOTORS%% *}"
for f in "$SH" "$PS1F"; do
    grep -q "MOTORS_ONE\|MotorsOne" "$f" || fail "$(basename "$f") has no single-motor spec"
    grep -q "'${FIRST_MOTOR}'\|\"${FIRST_MOTOR}\"" "$f" \
        || fail "$(basename "$f") single-motor spec is not the manifest's first entry ($FIRST_MOTOR)"
done
ok "single-motor spec is the manifest's first motor ($FIRST_MOTOR)"

# --- the release asset both flashers download ----------------------------
# Both build the filename from their app name, so match the path and the
# interpolation rather than a literal that is never spelled out in full.
for f in "$SH" "$PS1F"; do
    base="$(basename "$f")"
    grep -q 'releases/download/pi-image/' "$f" \
        || fail "$base does not download from the pi-image release"
    grep -Eq 'releases/download/pi-image/(\$\{?APP_NAME\}?|\$AppName)\.img\.xz' "$f" \
        || fail "$base's asset name is not built from its app name"
    grep -qi 'sha256\|checksum' "$f" || fail "$base does not verify a checksum"
    grep -q 'ERASE' "$f" || fail "$base does not require typing ERASE"
done
# And the app name they build it from has to be the manifest's.
grep -q "^APP_NAME=\"$APP_NAME\"$" "$SH" \
    || fail "bootstrap.sh's APP_NAME is not '$APP_NAME'"
grep -q "^\$AppName *= *'$APP_NAME'$" "$PS1F" \
    || fail "bootstrap.ps1's \$AppName is not '$APP_NAME'"
ok "both flashers fetch ${APP_NAME}.img.xz from the pinned release and verify its checksum"

# --- the write-time configuration contract -------------------------------
# Whatever the flashers write must be the filename firstboot.sh reads, and the
# keys must be ones it recognises. A typo here is silent: the card carries a
# config nothing ever reads, and the Pi comes up on the baked defaults.
for f in "$SH" "$PS1F"; do
    base="$(basename "$f")"
    grep -Eq '(\$\{?APP_NAME\}?|\$AppName)\.conf' "$f" \
        || fail "$base does not write <app>.conf onto the card"
    grep -qi 'configure.only\|ConfigureOnly' "$f" \
        || fail "$base has no re-addressing path"
done
ok "both flashers write ${APP_NAME}.conf and support re-configuring a card"

for key in ETH_ADDRESS ETH_PREFIX ETH_GATEWAY ETH_DNS PI_HOSTNAME SERVER_PORT \
           MOTORS PI_PASSWORD_B64 PI_SSH_PUBKEY; do
    grep -q "^        $key)" "$PI_IMAGE_DIR/firstboot.sh" \
        || fail "firstboot.sh does not recognise the key $key"
done
ok "firstboot.sh recognises every key the flashers can write"

for key in ETH_ADDRESS ETH_PREFIX ETH_GATEWAY ETH_DNS PI_HOSTNAME SERVER_PORT MOTORS; do
    grep -q "$key=" "$SH"   || fail "bootstrap.sh never writes $key"
    grep -q "'$key'" "$PS1F" || fail "bootstrap.ps1 never writes $key"
done
ok "both flashers write every setting firstboot.sh can apply"

# --- the unit/EnvironmentFile indirection --------------------------------
# This is what makes the port and motor set changeable without a rebuild. If
# APP_EXEC ever has them substituted in at build time instead, the card's config
# silently stops affecting them.
case "$APP_EXEC" in
    *'$PUMP_PORT'*)  ok "APP_EXEC leaves \$PUMP_PORT for systemd to expand" ;;
    *) fail "APP_EXEC does not reference \$PUMP_PORT; the port is baked in" ;;
esac
case "$APP_EXEC" in
    *'$MOTOR_ARGS'*) ok "APP_EXEC leaves \$MOTOR_ARGS for systemd to expand" ;;
    *) fail "APP_EXEC does not reference \$MOTOR_ARGS; the motor set is baked in" ;;
esac
grep -q "EnvironmentFile=/etc/\${APP_NAME}.env" "$PI_IMAGE_DIR/build.sh" \
    || fail "the rendered unit has no EnvironmentFile, so nothing can expand those"
ok "the unit reads its port and motor set from an EnvironmentFile"

# --- README ---------------------------------------------------------------
grep -q 'main/pi-image/bootstrap.sh'  "$README" || fail "README does not link the sh flasher"
grep -q 'main/pi-image/bootstrap.ps1' "$README" || fail "README does not link the ps1 flasher"
grep -q "$ETH_ADDRESS" "$README" || fail "README does not mention $ETH_ADDRESS"
grep -q 'no gateway' "$README" || fail "README does not explain the missing gateway"
grep -qi 'no authentication' "$README" || fail "README does not warn that the API is unauthenticated"
ok "README documents the flashers, the address and the isolated link"

# The pinout is the thing someone reads with a jumper wire in their hand, so
# every configured pin has to actually appear in it.
IFS=' '
# shellcheck disable=SC2086  # deliberate split: one motor entry per word
for entry in $MOTORS; do
    pins="${entry#*:}"
    IFS=','
    # shellcheck disable=SC2086  # deliberate split on the IFS set just above
    for p in $pins; do
        [ "$p" = "-1" ] && continue
        grep -q "GPIO$p\b" "$README" \
            || fail "README's pinout does not mention GPIO$p, which $MOTORS uses"
    done
    IFS=' '
done
unset IFS
ok "README's pinout covers every pin in MOTORS"

grep -qi 'ENABLE' "$README" || fail "README does not say what to do with the A4988 ENABLE pin"
grep -q '/motor/' "$README" || fail "README does not document the per-motor routes"
ok "README documents ENABLE and the per-motor API"

# --- platform coverage in the sh flasher ---------------------------------
grep -q 'Darwin' "$SH" || fail "bootstrap.sh does not handle macOS"
grep -q 'diskutil list external physical' "$SH" || fail "bootstrap.sh has no macOS disk listing"
grep -q 'shasum -a 256' "$SH" || fail "bootstrap.sh has no macOS checksum path"
grep -q 'Raspberry Pi Imager.app' "$SH" || fail "bootstrap.sh does not find Imager on macOS"
grep -q 'lsblk' "$SH" || fail "bootstrap.sh has no Linux disk listing"
ok "bootstrap.sh covers both Linux and macOS"

# Bash 3.2 is what macOS ships, and these are the constructs that break on it.
# Comments are stripped first: the script's own header explains that it avoids
# ${var^^}, and scanning the raw file flagged that sentence as a violation.
CODE_ONLY="$(sed 's/#.*//' "$SH")"
if grep -q 'declare -A' <<<"$CODE_ONLY"; then
    fail "bootstrap.sh uses an associative array (Bash 4+)"
elif grep -qE '\$\{[A-Za-z_]+\^\^?' <<<"$CODE_ONLY"; then
    fail "bootstrap.sh uses \${var^^} case conversion (Bash 4+)"
elif grep -qE '\b(readarray|mapfile)\b' <<<"$CODE_ONLY"; then
    fail "bootstrap.sh uses mapfile/readarray (Bash 4+)"
else
    ok "bootstrap.sh avoids Bash 4-only syntax"
fi

# --- CI publishes what the flashers download -----------------------------
WF="$ROOT/.github/workflows/pi-image.yml"
if [ -f "$WF" ]; then
    grep -q 'TAG="pi-image"' "$WF" || fail "CI does not publish the pi-image tag"
    grep -q "${APP_NAME}.img.xz.sha256" "$WF" \
        || fail "CI does not publish the checksum the flashers verify against"
    ok "CI publishes the asset and checksum the flashers expect"
else
    fail "no pi-image workflow"
fi

[ "$FAILED" = 0 ] || exit 1
echo "bootstrap wiring ok"
