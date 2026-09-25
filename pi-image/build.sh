#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Build a ready-to-flash Raspberry Pi image for this project.
#
#   sudo PI_PASSWORD=secret ./pi-image/build.sh [output.img.xz]
#
# Customises the OFFICIAL Raspberry Pi OS Lite image with sdm. Everything is
# installed at build time, so the resulting card needs no first-boot
# provisioning, no two-stage boot, and no network on the Pi: flash it and
# switch the Pi on.
#
# Everything project-specific lives in pi-app.env. A second instrument needs
# its own copy of that file and nothing else.
#
# The settings baked in here are only DEFAULTS. The flasher prompts for the
# address, hostname, port, password and motor count, and writes the answers to
# the card's boot partition, where firstboot.sh applies them on every boot --
# so a card can be re-addressed or re-configured without rebuilding a 1 GB
# image.
#
# Requires: Linux, root, sdm (installed automatically if absent).
# ---------------------------------------------------------------------------
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/.." && pwd)"

# shellcheck disable=SC1091
. "$HERE/pi-app.env"
# Allow the environment to override the manifest, so a password never has to
# be committed.
PI_PASSWORD="${PI_PASSWORD:-changeme}"
IMAGE_URL="${IMAGE_URL:?IMAGE_URL missing from pi-app.env}"

CACHE="${PI_IMAGE_CACHE:-/tmp/pi-image-cache}"
OUT="${1:-$REPO_ROOT/${APP_NAME}-$(date -u +%Y-%m-%d).img.xz}"

[ "$(id -u)" -eq 0 ] || { echo "must run as root (sdm needs it)" >&2; exit 1; }
if [ "$PI_PASSWORD" = "changeme" ]; then
    echo "WARNING: building with the default password. Set PI_PASSWORD, or set" >&2
    echo "         one per card at the flasher's prompt." >&2
fi

# --- sdm ------------------------------------------------------------------
# A maintained tool that already solves image customisation: user creation,
# the first-boot account wizard, cloud-init, machine-id, root expansion. All
# things worth not reimplementing.
# Pinned two ways: the installer is fetched by commit rather than from master,
# and it is asked for a specific release tag. Pinning only one of those leaves
# the other floating, which is how the user plugin renamed username= to
# adduser= underneath a build that had supposedly pinned sdm.
if ! command -v sdm >/dev/null 2>&1; then
    echo ">> installing sdm ${SDM_VERSION}"
    SDM_INSTALLER="https://raw.githubusercontent.com/gitbls/sdm/${SDM_COMMIT}/install-sdm"
    curl -fsSL "$SDM_INSTALLER" | bash -s -- "$SDM_VERSION"
fi

# Assert what we actually got. A pin that is never checked is a comment.
SDM_GOT="$(sdm --version 2>&1 || true)"
echo ">> $SDM_GOT"
case "$SDM_GOT" in
    *"$SDM_VERSION"*) ;;
    *) echo "ERROR: expected sdm $SDM_VERSION, got: $SDM_GOT" >&2
       echo "       Remove the installed sdm, or move the pin in pi-app.env." >&2
       exit 1 ;;
esac

# --- the base image -------------------------------------------------------
mkdir -p "$CACHE"
IMG="$CACHE/raspios.img"
if [ ! -f "$IMG" ]; then
    if [ ! -f "$CACHE/raspios.img.xz" ]; then
        echo ">> downloading Raspberry Pi OS Lite (about 500 MB, cached)"
        curl -fSL --retry 3 -o "$CACHE/raspios.img.xz.part" "$IMAGE_URL"
        mv "$CACHE/raspios.img.xz.part" "$CACHE/raspios.img.xz"
    fi
    # Verify before decompressing, and on every run -- CI restores this cache
    # by key prefix, so a stale or truncated entry would otherwise be
    # customised and shipped with nobody the wiser.
    if [ -n "${IMAGE_SHA256:-}" ]; then
        echo ">> verifying the base image checksum"
        if ! echo "${IMAGE_SHA256}  ${CACHE}/raspios.img.xz" | sha256sum -c -; then
            echo "ERROR: the base image does not match IMAGE_SHA256." >&2
            echo "       Delete ${CACHE}/raspios.img.xz and retry. If it still" >&2
            echo "       differs, IMAGE_URL was re-published and the pin needs a" >&2
            echo "       deliberate update." >&2
            exit 1
        fi
    else
        echo "WARNING: IMAGE_SHA256 is unset; the base image is unverified." >&2
    fi

    echo ">> decompressing"
    xz -dc "$CACHE/raspios.img.xz" > "$IMG.part" && mv "$IMG.part" "$IMG"
fi

# sdm customises in place, so work on a copy and keep the download reusable.
WORK="$CACHE/${APP_NAME}-work.img"
echo ">> preparing a working copy"
rm -f "$WORK"
cp --reflink=auto "$IMG" "$WORK"

# --- render the per-project files ----------------------------------------
BUILD="$(mktemp -d)"
trap 'rm -rf "$BUILD"' EXIT

VENV="${REPO_DEST}/.venv"
EXECSTART="${APP_EXEC//\$\{VENV\}/$VENV}"
EXECSTART="${EXECSTART//\$\{REPO_DEST\}/$REPO_DEST}"
EXECSTART="${EXECSTART//\$\{SERVER_PORT\}/$SERVER_PORT}"
# Only the BUILD-time placeholders must be gone. ${PUMP_PORT} deliberately
# survives into the unit for systemd to expand at start, so a blanket check for
# '${' would reject a correct command line.
for _ph in '${VENV}' '${REPO_DEST}' '${SERVER_PORT}'; do
    case "$EXECSTART" in
        *"$_ph"*)
            echo "ERROR: unsubstituted build-time placeholder $_ph in APP_EXEC:" >&2
            echo "       $EXECSTART" >&2
            exit 1 ;;
    esac
done

# --- the network profile --------------------------------------------------
# Gateway and DNS are written ONLY when the manifest asks for them. With
# neither there is no default route and no resolver on this interface, so the
# Pi cannot reach -- or be reached from -- anything but hosts on the same
# switch. firstboot.sh regenerates this file from the card's own config, so
# the copy baked here is the fallback for a card with nothing written to it.
#
# Kept as a function because firstboot.sh must produce byte-identical output
# from the same inputs; the two are checked against each other by the tests.
render_profile() {   # render_profile <address> <prefix> <gateway> <dns> <dest>
    local addr="$1" prefix="$2" gw="$3" dns="$4" dest="$5"
    {
        printf '[connection]\n'
        printf 'id=%s-static\n' "$ETH_IFACE"
        printf 'type=ethernet\n'
        printf 'interface-name=%s\n' "$ETH_IFACE"
        printf 'autoconnect=true\n'
        printf 'autoconnect-priority=100\n'
        printf '\n[ipv4]\n'
        printf 'method=manual\n'
        printf 'address1=%s/%s\n' "$addr" "$prefix"
        if [ -n "$gw" ]; then
            printf 'gateway=%s\n' "$gw"
        else
            printf 'never-default=true\n'
        fi
        if [ -n "$dns" ]; then
            printf 'dns=%s;\n' "$dns"
        else
            printf 'ignore-auto-dns=true\n'
        fi
        printf 'may-fail=false\n'
        printf '\n[ipv6]\n'
        printf 'method=disabled\n'
    } > "$dest"
    chmod 600 "$dest"
}
render_profile "$ETH_ADDRESS" "$ETH_PREFIX" "${ETH_GATEWAY:-}" "${ETH_DNS:-}" \
               "$BUILD/${ETH_IFACE}-static.nmconnection"

# --- runtime settings the unit reads, rather than has substituted ---------
# This indirection is the whole reason the port and the motor set can change at
# write time: systemd expands these when the service starts, so firstboot.sh
# only has to rewrite one small file rather than the unit.
"$HERE/render-motor-args.sh" "$MOTORS" > "$BUILD/motor-args"
cat > "$BUILD/${APP_NAME}.env" <<ENVFILE
PUMP_PORT=${SERVER_PORT}
MOTOR_ARGS=$(cat "$BUILD/motor-args")
ENVFILE

cat > "$BUILD/${APP_NAME}.service" <<UNIT
[Unit]
Description=${APP_NAME} motor server
After=network.target ${SERVICE_REQUIRES}
Requires=${SERVICE_REQUIRES}
# The card's own settings must be applied before the server reads its port.
After=${APP_NAME}-firstboot.service

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
# rather than leaving the motors unreachable mid-run.
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT

cat > "$BUILD/${APP_NAME}-firstboot.service" <<UNIT
[Unit]
Description=Apply ${APP_NAME} settings from the boot partition
# The config lives on the FAT partition, so it has to be mounted first.
After=local-fs.target
Requires=local-fs.target
# Both of these consume what this unit writes: the network profile, and the
# EnvironmentFile holding the port and the motor set.
Before=NetworkManager.service ${APP_NAME}.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/${APP_NAME}-firstboot
StandardOutput=journal+console
StandardError=journal+console

[Install]
WantedBy=multi-user.target
UNIT

# The phase script reads the manifest from PI_IMAGE_BUILD, exported below;
# sdm copies the script into the image, so it cannot find it any other way.
# The password comes from the environment rather than the committed file.
grep -v '^PI_PASSWORD=' "$HERE/pi-app.env" > "$BUILD/pi-app.env"
printf 'PI_PASSWORD=%s\n' "$PI_PASSWORD" >> "$BUILD/pi-app.env"
install -m 755 "$HERE/cscript.sh"           "$BUILD/cscript.sh"
install -m 755 "$HERE/firstboot.sh"         "$BUILD/firstboot.sh"
install -m 755 "$HERE/render-motor-args.sh" "$BUILD/render-motor-args.sh"

# --- customise ------------------------------------------------------------
echo ">> customising the image with sdm"
export PI_IMAGE_REPO="$REPO_ROOT"
export PI_IMAGE_BUILD="$BUILD"

sdm --customize "$WORK" \
    --hostname "$PI_HOSTNAME" \
    --extend --xmb "$GROW_MB" \
    --expand-root \
    --plugin "user:adduser=${PI_USER}|password=${PI_PASSWORD}|groups=sudo,adm,dialout,gpio,i2c,spi,video,plugdev,netdev" \
    --plugin "apps:apps=${APT_PACKAGES}" \
    --cscript "$BUILD/cscript.sh"

# --- compress -------------------------------------------------------------
echo ">> compressing (the slow part)"
rm -f "$OUT.part"
xz -T0 -6 -c "$WORK" > "$OUT.part" 2>/dev/null || xz -6 -c "$WORK" > "$OUT.part"
mv "$OUT.part" "$OUT"
rm -f "$WORK"

echo
echo "Built: $OUT  ($(du -h "$OUT" | cut -f1))"
echo
echo "Flash it with pi-image/bootstrap.sh or bootstrap.ps1. Those prompt for the"
echo "address, hostname, port, password and motor count and write them onto the"
echo "card, so one image serves every instrument."
echo
echo "Baked defaults, used only for a card with no config written to it:"
echo "  API: http://${ETH_ADDRESS}:${SERVER_PORT}"
echo "  SSH: ssh ${PI_USER}@${ETH_ADDRESS}"
echo "  Motors: ${MOTORS}"
