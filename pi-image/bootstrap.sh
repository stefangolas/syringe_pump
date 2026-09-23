#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Download the CI-audited sdm image, write it to removable media, and configure
# the card.
#
#   curl -fsSL https://raw.githubusercontent.com/stefangolas/syringe_pump/main/pi-image/bootstrap.sh | sudo bash
#
# After writing the image it prompts for the address, hostname, port, motor
# count and password, and writes them onto the card's FAT boot partition, where
# firstboot.sh applies them on every boot. Press Enter to accept the value shown
# in brackets.
#
#   --configure-only <path>   rewrite the settings on a card that already has
#                             this image, without re-writing the image
#   --defaults                take every default, ask nothing
#
# No associative arrays and no ${var^^}: macOS ships Bash 3.2, and this has to
# run there unmodified.
# ---------------------------------------------------------------------------
set -euo pipefail

APP_NAME="syringe-pump"
IMAGE_URL="https://github.com/stefangolas/syringe_pump/releases/download/pi-image/${APP_NAME}.img.xz"
SHA_URL="${IMAGE_URL}.sha256"
CACHE="${SP_IMAGE_CACHE:-/var/tmp/${APP_NAME}-sdm}"
IMAGE="$CACHE/${APP_NAME}.img.xz"
OS="$(uname -s)"

# Defaults, kept in step with pi-image/pi-app.env. A test asserts they match,
# because this script is fetched standalone and cannot read the manifest.
D_ETH_ADDRESS="10.194.22.184"
D_ETH_PREFIX="24"
D_ETH_GATEWAY=""
D_ETH_DNS=""
D_PI_HOSTNAME="syringe-pump"
D_PI_USER="chorylab"
D_SERVER_PORT="5000"
D_MOTORS="a:22,23,17,27,25 b:5,6,13,19,26"
# Dropping the second entry is how a card is made single-motor.
MOTORS_ONE="a:22,23,17,27,25"

CONFIGURE_ONLY=""
USE_DEFAULTS=0
while [ $# -gt 0 ]; do
    case "$1" in
        --configure-only) CONFIGURE_ONLY="${2:-}"; shift 2 ;;
        --defaults)       USE_DEFAULTS=1; shift ;;
        -h|--help)        sed -n '2,20p' "$0"; exit 0 ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done

# When piped from curl, stdin is the script itself -- prompt on the terminal.
# Testing -r is not enough: /dev/tty can exist and still fail to open when
# there is no controlling terminal (CI, a service, a captured shell), and an
# unguarded redirect then kills the script before it prints anything.
if ! { exec 3</dev/tty; } 2>/dev/null; then exec 3<&0; fi
ask_raw() { printf '%s' "$1" >&2; read -r "$2" <&3; }

# --- prompt helpers -------------------------------------------------------
# Every prompt shows its default in brackets and accepts Enter. Validation
# happens here as well as on the Pi: being told "that is not an IPv4 address"
# now beats discovering it when the instrument does not come up.
is_ipv4() {
    local ip="$1" o rest count=0
    [ -n "$ip" ] || return 1
    case "$ip" in *[!0-9.]*) return 1 ;; esac
    rest="$ip"
    while [ -n "$rest" ]; do
        o="${rest%%.*}"
        if [ "$o" = "$rest" ]; then rest=""; else rest="${rest#*.}"; fi
        [ -n "$o" ] || return 1
        [ "$o" -le 255 ] 2>/dev/null || return 1
        count=$((count + 1))
    done
    [ "$count" -eq 4 ]
}

is_num_in() {   # is_num_in <value> <min> <max>
    case "$1" in ''|*[!0-9]*) return 1 ;; esac
    [ "$1" -ge "$2" ] && [ "$1" -le "$3" ]
}

is_hostname() {
    case "$1" in
        ''|-*|*-) return 1 ;;
        *[!a-zA-Z0-9-]*) return 1 ;;
    esac
    [ "${#1}" -le 63 ]
}

# ask <varname> <question> <default> <validator> <hint>
# The validator is the name of a function taking the candidate value; the empty
# string means "accept anything".
ask() {
    local __var="$1" question="$2" default="$3" validator="$4" hint="$5"
    local shown answer
    if [ "$USE_DEFAULTS" = 1 ]; then
        eval "$__var=\$default"
        return 0
    fi
    while :; do
        shown="$default"
        [ -n "$shown" ] || shown="<none>"
        ask_raw "$question [$shown]: " answer
        if [ -z "$answer" ]; then
            eval "$__var=\$default"
            return 0
        fi
        # A literal "none" is how a prompt with a non-empty default is cleared,
        # since Enter means "keep it" and an empty line cannot mean both.
        [ "$answer" = none ] && answer=""
        if [ -z "$validator" ] || "$validator" "$answer"; then
            eval "$__var=\$answer"
            return 0
        fi
        echo "  not valid: $hint" >&2
    done
}

# Allows an empty value through, for the optional gateway and DNS.
is_ipv4_or_empty() { [ -z "$1" ] || is_ipv4 "$1"; }
is_addr_required()  { is_ipv4 "$1"; }
is_prefix()   { is_num_in "$1" 1 32; }
is_port()     { is_num_in "$1" 1 65535; }
is_one_or_two() { [ "$1" = 1 ] || [ "$1" = 2 ]; }

CFG_PASSWORD_B64=""
read_card_settings() {
    echo >&2
    echo "Card settings" >&2
    echo 'Press Enter to accept the value in brackets. Type "none" to clear one.' >&2
    echo >&2

    ask CFG_ETH_ADDRESS "Static IP address for the Pi" "$D_ETH_ADDRESS" \
        is_addr_required "e.g. 10.194.22.184"
    ask CFG_ETH_PREFIX  "Subnet prefix length" "$D_ETH_PREFIX" \
        is_prefix "1-32, e.g. 24"
    if [ "$USE_DEFAULTS" != 1 ]; then
        echo "  Leave the gateway and DNS empty for an isolated link: with no default" >&2
        echo "  route the Pi is reachable only from hosts on the same switch. The" >&2
        echo "  server has NO authentication, so on a routed LAN anyone who can reach" >&2
        echo "  the port can drive the pump." >&2
    fi
    ask CFG_ETH_GATEWAY "Gateway (empty = isolated)" "$D_ETH_GATEWAY" \
        is_ipv4_or_empty "an IPv4 address, or none"
    ask CFG_ETH_DNS     "DNS server (empty = none)" "$D_ETH_DNS" \
        is_ipv4_or_empty "an IPv4 address, or none"
    ask CFG_PI_HOSTNAME "Hostname" "$D_PI_HOSTNAME" \
        is_hostname "letters, digits and hyphens"
    ask CFG_SERVER_PORT "Server port" "$D_SERVER_PORT" \
        is_port "1-65535"

    echo >&2
    ask MOTOR_COUNT "How many motors on this Pi? (1 or 2)" "2" is_one_or_two "1 or 2"
    if [ "$MOTOR_COUNT" = 1 ]; then
        CFG_MOTORS="$MOTORS_ONE"
    else
        CFG_MOTORS="$D_MOTORS"
    fi
    echo "  motors: $CFG_MOTORS" >&2
    echo "  Each motor is commanded separately at /motor/<id>/run." >&2

    # --- password ---------------------------------------------------------
    # Optional: Enter leaves whatever the image was built with. Base64 because
    # this file is written by PowerShell on Windows and read by bash here, and
    # any quoting scheme that survives one can break the other.
    CFG_PASSWORD_B64=""
    if [ "$USE_DEFAULTS" != 1 ]; then
        echo >&2
        echo "Password for the \"$D_PI_USER\" account (SSH login)." >&2
        echo "Leave BOTH blank to keep the password the image was built with." >&2
        printf 'Password: ' >&2; read -rs PW1 <&3; echo >&2
        printf 'Again: ' >&2;    read -rs PW2 <&3; echo >&2
        if [ -n "${PW1:-}" ] || [ -n "${PW2:-}" ]; then
            [ "$PW1" = "$PW2" ] || { echo "Passwords do not match." >&2; exit 1; }
            CFG_PASSWORD_B64="$(printf '%s' "$PW1" | base64 | tr -d '\n')"
        fi
        unset PW1 PW2
    fi
}

write_card_settings() {   # write_card_settings <boot-mountpoint>
    local boot target log
    boot="$1"
    target="$boot/${APP_NAME}.conf"
    log="$boot/${APP_NAME}-firstboot.log"
    {
        echo "# ${APP_NAME} card settings, written by bootstrap.sh on $(date -u '+%Y-%m-%d %H:%M UTC')."
        echo "#"
        echo "# Read on EVERY boot by /usr/local/sbin/${APP_NAME}-firstboot. Edit this file"
        echo "# and reboot the Pi to change any of it -- no reflash needed. A key left out"
        echo "# falls back to the value baked into the image."
        echo "#"
        echo "# An invalid value is refused as a whole and nothing is applied, so a typo"
        echo "# cannot strand the instrument. The result is logged beside this file as"
        echo "# ${APP_NAME}-firstboot.log."
        echo "ETH_ADDRESS=$CFG_ETH_ADDRESS"
        echo "ETH_PREFIX=$CFG_ETH_PREFIX"
        echo "ETH_GATEWAY=$CFG_ETH_GATEWAY"
        echo "ETH_DNS=$CFG_ETH_DNS"
        echo "PI_HOSTNAME=$CFG_PI_HOSTNAME"
        echo "SERVER_PORT=$CFG_SERVER_PORT"
        echo "MOTORS=$CFG_MOTORS"
        [ -n "$CFG_PASSWORD_B64" ] && echo "PI_PASSWORD_B64=$CFG_PASSWORD_B64"
    } > "$target"
    echo "  wrote $target"

    # Retire a log from a previous boot: it describes a configuration that is no
    # longer on the card, and reading it as current would mislead.
    if [ -f "$log" ]; then
        mv -f "$log" "$log.prev"
        echo "  kept the previous boot log as ${APP_NAME}-firstboot.log.prev"
    fi
}

show_next() {
    local addr port controller subnet last
    addr="$CFG_ETH_ADDRESS"
    port="$CFG_SERVER_PORT"
    controller=""
    # The example controller address has to sit on the Pi's own subnet, so it is
    # derived rather than hardcoded -- a hardcoded one contradicts the address
    # printed above it the first time the address is changed.
    if is_ipv4 "$addr"; then
        subnet="${addr%.*}"; last="${addr##*.}"
        if [ "$last" = 2 ]; then controller="$subnet.3"; else controller="$subnet.2"; fi
    fi

    echo
    if [ -n "$CFG_ETH_GATEWAY" ]; then
        echo "Done. The Pi will join your LAN at the address above."
        echo "Put the media in the Pi and switch it on."
    else
        echo "Almost done. NOTHING on the Pi link hands out addresses, so this machine"
        echo "must be given a static address before the Pi is reachable:"
        echo
        echo "  1. Connect this machine to the Pi with an Ethernet cable."
        echo "  2. Set a static address on the wired adapter:"
        echo
        if [ "$OS" = Linux ]; then
            echo "       ip -br link                                    # find the wired interface"
            echo "       sudo ip addr add $controller/$CFG_ETH_PREFIX dev eth0    # eth0 = that interface"
            echo
            echo "     No gateway, no DNS. Undo later with:"
            echo "       sudo ip addr del $controller/$CFG_ETH_PREFIX dev eth0"
        else
            echo "       networksetup -listallhardwareports              # find the wired interface"
            echo "       sudo ifconfig en5 $controller/$CFG_ETH_PREFIX             # en5 = that interface"
            echo
            echo "     No gateway, no DNS. Undo later with:"
            echo "       sudo ipconfig set en5 DHCP"
        fi
        echo
        echo "  3. Put the media in the Pi and switch it on."
    fi
    echo
    echo "  The Pi answers at:"
    echo "       API:    http://${addr}:${port}"
    echo "       motors: http://${addr}:${port}/motors"
    echo "       SSH:    ssh ${D_PI_USER}@${addr}"
    echo
    echo "  Motors: $CFG_MOTORS"
    echo "     run:  POST http://${addr}:${port}/motor/a/run   {\"steps\": 600}"
    echo "     stop: POST http://${addr}:${port}/motor/a/stop"
    echo
    echo "  To change any of this later: edit ${APP_NAME}.conf on the card's boot"
    echo "  partition and reboot the Pi. No reflash, no rebuild."
    if [ -z "$CFG_PASSWORD_B64" ]; then
        echo
        echo "  NOTE: no password was set, so the image's build credential still applies."
    fi
}

# --- the re-addressing path ----------------------------------------------
# Deliberately first and separate: it touches no disk except the FAT partition,
# needs no download, no root and no Imager. It is the common case once a card
# has been written once.
if [ -n "$CONFIGURE_ONLY" ]; then
    [ -f "$CONFIGURE_ONLY/cmdline.txt" ] || {
        echo "$CONFIGURE_ONLY has no cmdline.txt - that is not a Raspberry Pi boot partition." >&2
        exit 2
    }
    echo
    echo "=== ${APP_NAME} card configuration ==="
    echo "Configuring the card at $CONFIGURE_ONLY (the image is not being rewritten)"
    read_card_settings
    write_card_settings "$CONFIGURE_ONLY"
    show_next
    exit 0
fi

[ "$(id -u)" -eq 0 ] || { echo "Run with sudo." >&2; exit 1; }
for tool in curl awk base64; do
    command -v "$tool" >/dev/null || { echo "Missing required tool: $tool" >&2; exit 1; }
done
case "$OS" in
    Linux)
        for tool in xz sha256sum lsblk dd; do
            command -v "$tool" >/dev/null || { echo "Missing required tool: $tool" >&2; exit 1; }
        done
        sha256_file() { sha256sum "$1" | awk '{print $1}'; }
        ;;
    Darwin)
        for tool in shasum diskutil; do
            command -v "$tool" >/dev/null || { echo "Missing required tool: $tool" >&2; exit 1; }
        done
        IMAGER="/Applications/Raspberry Pi Imager.app/Contents/MacOS/rpi-imager"
        [ -x "$IMAGER" ] || IMAGER="/Applications/Raspberry Pi Imager.app/Contents/MacOS/Raspberry Pi Imager"
        [ -x "$IMAGER" ] || {
            echo "Install Raspberry Pi Imager from https://www.raspberrypi.com/software/" >&2
            exit 1
        }
        sha256_file() { shasum -a 256 "$1" | awk '{print $1}'; }
        ;;
    *) echo "Unsupported operating system: $OS" >&2; exit 1 ;;
esac

echo
echo "=== ${APP_NAME} ready-image flasher ==="
echo
echo "Removable drives:"
DISKS=()
if [ "$OS" = Linux ]; then
    while IFS= read -r dev; do DISKS[${#DISKS[@]}]="$dev"; done \
        < <(lsblk -dpno NAME,RM | awk '$2==1 {print $1}')
else
    while IFS= read -r dev; do DISKS[${#DISKS[@]}]="$dev"; done \
        < <(diskutil list external physical | awk '/^\/dev\/disk[0-9]+/ {print $1}')
fi
[ "${#DISKS[@]}" -gt 0 ] || { echo "No removable drive found." >&2; exit 1; }
for i in "${!DISKS[@]}"; do
    DEV="${DISKS[$i]}"
    if [ "$OS" = Linux ]; then
        DESC="$(lsblk -dno SIZE,MODEL "$DEV")"
    else
        DESC="$(diskutil info "$DEV" | awk -F: '/Media Name|Disk Size/ {gsub(/^[ \t]+/,"",$2); printf "%s ",$2}')"
    fi
    echo "  [$((i+1))] $DEV  $DESC"
done
ask_raw "Which one? [1-${#DISKS[@]}] " CHOICE
case "$CHOICE" in ''|*[!0-9]*) echo "Invalid selection." >&2; exit 1 ;; esac
[ "$CHOICE" -ge 1 ] && [ "$CHOICE" -le "${#DISKS[@]}" ] ||
    { echo "Invalid selection." >&2; exit 1; }
DEV="${DISKS[$((CHOICE-1))]}"
[ -b "$DEV" ] || { echo "Not a block device: $DEV" >&2; exit 1; }
if [ "$OS" = Linux ]; then
    [ "$(lsblk -dno RM "$DEV" | tr -d ' ')" = 1 ] ||
        { echo "$DEV is not removable. Refusing." >&2; exit 1; }
else
    INFO="$(diskutil info "$DEV")"
    echo "$INFO" | grep -Eq 'Device Location:[[:space:]]+External' ||
        { echo "$DEV is not external. Refusing." >&2; exit 1; }
    echo "$INFO" | grep -Eq 'Whole:[[:space:]]+Yes' ||
        { echo "$DEV is not a whole disk. Refusing." >&2; exit 1; }
fi

echo
echo "  !! $DEV will be COMPLETELY ERASED"
if [ "$OS" = Linux ]; then lsblk -o NAME,SIZE,MODEL,MOUNTPOINT "$DEV"
else diskutil info "$DEV" | grep -E 'Device Node|Media Name|Disk Size|Device Location'; fi
ask_raw "  Type ERASE to continue: " CONFIRM
[ "$CONFIRM" = ERASE ] || { echo "Aborted."; exit 1; }

# Asked BEFORE the download and the write, so the long unattended part of the
# run is the part that needs no one sitting in front of it.
read_card_settings

mkdir -p "$CACHE"
echo
echo ">> fetching the published checksum"
curl -fsSL --retry 3 -o "$CACHE/${APP_NAME}.img.xz.sha256" "$SHA_URL"
EXPECTED="$(awk '{print $1}' "$CACHE/${APP_NAME}.img.xz.sha256")"
case "$EXPECTED" in
    [0-9a-f][0-9a-f][0-9a-f][0-9a-f]*) ;;
    *) echo "Published checksum is invalid." >&2; exit 1 ;;
esac
[ "${#EXPECTED}" -eq 64 ] || { echo "Published checksum is invalid." >&2; exit 1; }

if [ ! -f "$IMAGE" ] || [ "$(sha256_file "$IMAGE")" != "$EXPECTED" ]; then
    echo ">> downloading the ready-to-flash image (about 1 GB)"
    curl -fL --retry 3 -o "$IMAGE.part" "$IMAGE_URL"
    mv "$IMAGE.part" "$IMAGE"
else
    echo ">> using the verified cached image"
fi
[ "$(sha256_file "$IMAGE")" = "$EXPECTED" ] || {
    echo "Downloaded image checksum does not match the published checksum." >&2; exit 1;
}

if [ "$OS" = Linux ]; then
    xz -t "$IMAGE"
    while read -r part; do
        [ "$part" = "$DEV" ] || umount "$part" 2>/dev/null || true
    done < <(lsblk -lnpo NAME "$DEV")
    echo ">> writing the audited image"
    xz -dc "$IMAGE" | dd of="$DEV" bs=4M conv=fsync status=progress
    sync
    # Force a partition-table re-read: most card readers get a udev rescan for
    # free, but not all, and the FAT node has to exist before it can be mounted.
    partprobe "$DEV" 2>/dev/null || blockdev --rereadpt "$DEV" 2>/dev/null || true
    sleep 3
else
    echo ">> writing and verifying the audited image"
    diskutil unmountDisk "$DEV"
    "$IMAGER" --cli "$IMAGE" "$DEV"
fi

# --- write the settings onto the card ------------------------------------
echo ">> saving the card's settings"
BOOTMNT=""
if [ "$OS" = Linux ]; then
    BOOTPART="$(lsblk -lno NAME,FSTYPE "$DEV" | awk '$2=="vfat"{print "/dev/"$1; exit}')"
    [ -n "$BOOTPART" ] || BOOTPART="${DEV}1"
    BOOTMNT="$(mktemp -d)"
    if mount "$BOOTPART" "$BOOTMNT" 2>/dev/null; then
        write_card_settings "$BOOTMNT"
        sync
        umount "$BOOTMNT"
    else
        rmdir "$BOOTMNT"; BOOTMNT=""
    fi
    [ -n "$BOOTMNT" ] && rmdir "$BOOTMNT" 2>/dev/null || true
else
    diskutil mountDisk "$DEV" >/dev/null 2>&1 || true
    for candidate in /Volumes/bootfs /Volumes/boot; do
        if [ -f "$candidate/cmdline.txt" ]; then BOOTMNT="$candidate"; break; fi
    done
    if [ -n "$BOOTMNT" ]; then
        write_card_settings "$BOOTMNT"
        sync
    fi
fi

if [ -z "${BOOTMNT:-}" ]; then
    # The image is on the card and is usable with its baked defaults, so this is
    # recoverable without rewriting a gigabyte. Say exactly how.
    echo
    echo "WARNING: the image was written but the boot partition could not be mounted," >&2
    echo "         so the settings were not saved to the card. The Pi will come up on" >&2
    echo "         the built-in defaults (${D_ETH_ADDRESS}). Re-insert the card and run:" >&2
    echo "             sudo bash bootstrap.sh --configure-only /path/to/bootfs" >&2
    exit 1
fi

show_next
