#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# sdm custom phase script.
#
# Invoked by sdm as:  cscript.sh <phase>   where phase is 0 | 1 | post-install
#
#   phase 0        runs on the HOST with the image mounted at $SDMPT. Both
#                  filesystems are visible, so this is where files are copied in.
#   phase 1        runs INSIDE the image, but BEFORE sdm's own plugins. The
#                  account does not exist yet and the apt packages are not
#                  installed yet, so almost nothing belongs here.
#   post-install   also inside the image, AFTER sdm's plugins. The account
#                  exists and APT_PACKAGES are installed, so this is where the
#                  runtime gets built.
#
# The phase order is sdm's, not ours: sdm-phase1 runs the cscript's phase 1,
# then runplugins 1, then the cscript's post-install. Putting the venv build
# in phase 1 meant chown ran against a user that did not exist, and the
# RPi.GPIO check only passed because the base image happened to ship it.
#
# Everything project-specific comes from pi-app.env.
# ---------------------------------------------------------------------------
set -euo pipefail

phase="${1:-}"

# sdm copies this script INTO the image and runs it from there, so the
# manifest is not sitting beside it at run time. Phase 0 runs on the host,
# where build.sh's exports are visible, so it takes the staging directory
# from the environment; the later phases read the copy phase 0 planted.
CONF_IMG=/etc/pi-image-app.env

case "$phase" in

0)
    echo "cscript phase 0: staging files into the image"
    : "${PI_IMAGE_BUILD:?phase 0 needs PI_IMAGE_BUILD, exported by build.sh}"
    CONF_HOST="$PI_IMAGE_BUILD/pi-app.env"
    # shellcheck disable=SC1090
    . "$CONF_HOST"

    # Carry the manifest into the image so the later phases can read it.
    install -m 600 "$CONF_HOST" "$SDMPT$CONF_IMG"

    # --- the application ---------------------------------------------------
    # Excludes come from the manifest, so this script needs no knowledge of
    # which project it is building.
    EXCLUDE_ARGS=()
    IFS=','
    # shellcheck disable=SC2086  # deliberate split on the comma-separated list
    for pattern in $REPO_EXCLUDES; do
        [ -n "$pattern" ] && EXCLUDE_ARGS+=("--exclude=$pattern")
    done
    unset IFS

    install -d "$SDMPT$REPO_DEST"
    tar -C "$PI_IMAGE_REPO" "${EXCLUDE_ARGS[@]}" -cf - . \
        | tar -C "$SDMPT$REPO_DEST" -xf -

    # SERVER_PROJECT lives under pi-image/, which REPO_EXCLUDES drops -- the
    # rest of that directory is build-time tooling the instrument must not
    # carry. The frozen pyproject.toml and uv.lock are the exception, and
    # post-install installs from them, so copy them back in explicitly rather
    # than trying to punch a hole in a tar exclude.
    [ -f "$PI_IMAGE_REPO/$SERVER_PROJECT/uv.lock" ] || {
        echo "ERROR: $SERVER_PROJECT/uv.lock not found in the repo." >&2
        exit 1
    }
    install -d "$SDMPT$REPO_DEST/$SERVER_PROJECT"
    install -m 644 "$PI_IMAGE_REPO/$SERVER_PROJECT/pyproject.toml" \
                   "$PI_IMAGE_REPO/$SERVER_PROJECT/uv.lock" \
                   "$SDMPT$REPO_DEST/$SERVER_PROJECT/"

    # --- network profile ---------------------------------------------------
    # sdm's network plugin can also place this, but writing it here keeps one
    # source of truth for its contents. firstboot.sh regenerates it from the
    # card's own config, so this is the fallback for an uncustomised card.
    install -d -m 700 "$SDMPT/etc/NetworkManager/system-connections"
    install -m 600 "$PI_IMAGE_BUILD/${ETH_IFACE}-static.nmconnection" \
        "$SDMPT/etc/NetworkManager/system-connections/${ETH_IFACE}-static.nmconnection"

    # --- units and their runtime settings ----------------------------------
    install -d -m 755 "$SDMPT/etc/systemd/system"
    install -m 644 "$PI_IMAGE_BUILD/${APP_NAME}.service" \
        "$SDMPT/etc/systemd/system/${APP_NAME}.service"
    install -m 644 "$PI_IMAGE_BUILD/${APP_NAME}-firstboot.service" \
        "$SDMPT/etc/systemd/system/${APP_NAME}-firstboot.service"
    # The EnvironmentFile the unit reads its port and motor set from.
    install -m 644 "$PI_IMAGE_BUILD/${APP_NAME}.env" \
        "$SDMPT/etc/${APP_NAME}.env"

    # --- write-time configuration -----------------------------------------
    # firstboot.sh derives the app name from its own filename, which is what
    # lets it stay byte-identical between instruments.
    install -d -m 755 "$SDMPT/usr/local/sbin"
    install -m 755 "$PI_IMAGE_BUILD/firstboot.sh" \
        "$SDMPT/usr/local/sbin/${APP_NAME}-firstboot"
    install -d -m 755 "$SDMPT/usr/local/lib/${APP_NAME}"
    install -m 755 "$PI_IMAGE_BUILD/render-motor-args.sh" \
        "$SDMPT/usr/local/lib/${APP_NAME}/render-motor-args.sh"
    # firstboot.sh needs the manifest's non-secret values at RUN time, to fall
    # back on for anything the card's config leaves out. The password is
    # stripped: unlike $CONF_IMG this file stays in the finished image.
    grep -v '^PI_PASSWORD=' "$CONF_HOST" > "$SDMPT/etc/${APP_NAME}-defaults.env"
    chmod 644 "$SDMPT/etc/${APP_NAME}-defaults.env"
    ;;

1)
    # Deliberately empty. sdm has not run its plugins yet, so there is no
    # account to own files and no redis-server or python3-rpi.gpio to build
    # against. Everything real happens in post-install.
    echo "cscript phase 1: nothing to do before sdm's plugins run"
    ;;

post-install)
    echo "cscript post-install: building the runtime inside the image"
    # shellcheck disable=SC1091
    . "$CONF_IMG"
    VENV="${REPO_DEST}/.venv"
    PROJECT="${REPO_DEST}/${SERVER_PROJECT}"

    # uv, pinned. This runs at BUILD time, so the Pi itself never needs a
    # network -- which is the entire point of baking the image.
    if ! command -v uv >/dev/null 2>&1; then
        curl -LsSf "https://astral.sh/uv/${UV_VERSION}/install.sh" \
            | env UV_INSTALL_DIR=/usr/local/bin INSTALLER_NO_MODIFY_PATH=1 sh
    fi
    UV_GOT="$(uv --version 2>&1 || true)"
    echo "$UV_GOT"
    case "$UV_GOT" in
        *"$UV_VERSION"*) ;;
        *) echo "ERROR: expected uv $UV_VERSION, got: $UV_GOT" >&2; exit 1 ;;
    esac

    # System interpreter with system site-packages, so apt's prebuilt
    # RPi.GPIO stays importable. A uv-managed standalone Python would hide it.
    rm -rf "$VENV"
    uv venv --python /usr/bin/python3 --system-site-packages "$VENV"

    # uv.lock records the complete resolution and artifact hashes. --frozen
    # makes any drift between pyproject.toml and the lock fatal instead of
    # silently resolving a different environment during an image build.
    # Point uv at the venv created above so apt's RPi.GPIO remains visible.
    [ -f "$PROJECT/uv.lock" ] || {
        echo "ERROR: $PROJECT/uv.lock is missing; SERVER_PROJECT is wrong or" >&2
        echo "       the lock was not committed." >&2
        exit 1
    }
    UV_PROJECT_ENVIRONMENT="$VENV" uv sync \
        --project "$PROJECT" --frozen --no-dev --python /usr/bin/python3

    # Verify by spec, not import, for RPi.GPIO: it raises on non-Pi hardware,
    # and this is running under emulation on a build machine. The pure-Python
    # modules are imported for real, from the manifest's list.
    PYTHON_IMPORTS="$PYTHON_IMPORTS" "$VENV/bin/python" - <<'PYCHECK'
import importlib
import importlib.util as u
import os

for name in os.environ["PYTHON_IMPORTS"].split(","):
    name = name.strip()
    if name:
        importlib.import_module(name)
        print("  import %s ok" % name)
assert u.find_spec("RPi.GPIO"), "RPi.GPIO is not visible in the venv"
print("deps ok")
PYCHECK

    # The repo landed in phase 0, before the account existed, so nothing under
    # the home directory is owned by anyone yet.
    chown -R "${PI_USER}:${PI_USER}" "/home/${PI_USER}"

    if [ -n "${PI_SSH_PUBKEY:-}" ]; then
        install -d -m 700 -o "$PI_USER" -g "$PI_USER" "/home/${PI_USER}/.ssh"
        printf '%s\n' "$PI_SSH_PUBKEY" > "/home/${PI_USER}/.ssh/authorized_keys"
        chown "${PI_USER}:${PI_USER}" "/home/${PI_USER}/.ssh/authorized_keys"
        chmod 600 "/home/${PI_USER}/.ssh/authorized_keys"
    fi

    # sdm has no --timezone switch; set it here where it is unambiguous.
    if [ -n "${TIMEZONE:-}" ] && [ -e "/usr/share/zoneinfo/${TIMEZONE}" ]; then
        ln -sf "/usr/share/zoneinfo/${TIMEZONE}" /etc/localtime
        echo "${TIMEZONE}" > /etc/timezone
    fi

    systemctl enable "${APP_NAME}-firstboot.service"
    systemctl enable "${APP_NAME}.service"
    systemctl enable ssh

    # NM auto-creates a DHCP profile for a wired interface at RUN time, not in
    # the image, so there is nothing here to delete. The supported way to stop
    # it is no-auto-default; our profile's priority would probably win anyway,
    # but "probably" is not a plan for the only route onto the instrument.
    install -d -m 755 /etc/NetworkManager/conf.d
    cat > /etc/NetworkManager/conf.d/00-no-auto-default.conf <<'NMCONF'
# Do not invent a DHCP profile for wired interfaces. This Pi's address is
# static and set by the profile in the image, or by the card's own config.
[main]
no-auto-default=*
NMCONF

    rm -f "$CONF_IMG"
    ;;
esac
