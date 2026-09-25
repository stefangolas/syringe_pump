#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Turn the manifest's MOTORS spec into motor_server.py arguments.
#
#   render-motor-args.sh "a:22,23,17,27,25 b:5,6,13,19,26"
#   -> --motor a:22,23,17,27,25 --motor b:5,6,13,19,26
#
# Shared by build.sh (baking the default) and firstboot.sh (applying whatever
# the card says), so both produce byte-identical arguments from the same spec.
#
# Validation lives here rather than in either caller because a bad pin set
# should fail the build, or fail loudly at boot with the reason on the card --
# not silently start a server that drives the wrong header pins.
#
# Spec, space-separated, one entry per motor:
#   <id>:<dir>,<step>[,<ms1>,<ms2>,<ms3>]
#
# The three microstep pins are optional: omit them when MS1/MS2/MS3 are
# strapped in hardware, and -1,-1,-1 is passed so the driver leaves them
# alone. That matters on this header, because the usual mode pins sit on the
# SPI bus lines.
# ---------------------------------------------------------------------------
set -euo pipefail

SPEC="${1:-}"
[ -n "$SPEC" ] || { echo "render-motor-args.sh: empty MOTORS spec" >&2; exit 2; }

die() { echo "render-motor-args.sh: $*" >&2; exit 2; }

OUT=""
SEEN_IDS=" "
SEEN_PINS=" "

# shellcheck disable=SC2086  # deliberate split: one motor entry per word
for entry in $SPEC; do
    case "$entry" in
        *:*) ;;
        *) die "entry '$entry' is not <id>:<pins>" ;;
    esac
    id="${entry%%:*}"
    pins="${entry#*:}"

    # The id becomes part of a URL path and a Redis key, so keep it to
    # something that needs no escaping in either.
    case "$id" in
        '' ) die "entry '$entry' has an empty id" ;;
        *[!a-z0-9_-]* ) die "motor id '$id' must be lowercase a-z, 0-9, _ or -" ;;
    esac
    case "$SEEN_IDS" in
        *" $id "*) die "motor id '$id' is used twice" ;;
    esac
    SEEN_IDS="$SEEN_IDS$id "

    # Count and range-check the pins. BCM numbering runs 0-27 on a 40-pin
    # header; anything else is a typo that would otherwise surface as a
    # confusing RPi.GPIO error on the instrument.
    n=0
    IFS=','
    # shellcheck disable=SC2086  # deliberate split on the IFS set just above
    for p in $pins; do
        n=$((n + 1))
        case "$p" in
            -1) continue ;;
            '' ) die "entry '$entry' has an empty pin" ;;
            *[!0-9]* ) die "pin '$p' in '$entry' is not a number" ;;
        esac
        [ "$p" -le 27 ] || die "pin $p in '$entry' is outside BCM 0-27"
        # Two motors driven from one pin is always a wiring mistake, and a
        # silent one: both would step together.
        case "$SEEN_PINS" in
            *" $p "*) die "pin $p is assigned to more than one motor" ;;
        esac
        SEEN_PINS="$SEEN_PINS$p "
    done
    unset IFS

    case "$n" in
        2) pins="${pins},-1,-1,-1" ;;
        5) ;;
        *) die "entry '$entry' has $n pins; expected 2 (dir,step) or 5 (dir,step,ms1,ms2,ms3)" ;;
    esac

    OUT="$OUT --motor $id:$pins"
done

# Leading space trimmed so the value drops straight into an EnvironmentFile.
printf '%s\n' "${OUT# }"
