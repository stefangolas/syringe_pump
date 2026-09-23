<#
  Download the CI-audited sdm image, write it, and configure the card:

    irm https://raw.githubusercontent.com/stefangolas/syringe_pump/main/pi-image/bootstrap.ps1 | iex

  Run from an ADMINISTRATOR PowerShell. After writing the image it prompts for
  the address, hostname, port, motor count and password, and writes them onto
  the card's FAT boot partition, where firstboot.sh applies them on every boot.
  Press Enter at any prompt to accept the value shown in brackets.

  Requires Raspberry Pi Imager: https://www.raspberrypi.com/software/
#>
param(
    [int]$DiskNumber = -1,
    # Imager refuses a destination it does not consider removable. Built-in
    # PCIe card readers do not advertise removability -- Windows reports some
    # as BusType SCSI -- so a genuine SD card can be rejected. This overrules
    # that check, and is deliberately opt-in: it is the one guard that would
    # still catch a second internal drive that is neither the boot nor the
    # system disk, which our own checks let through.
    [switch]$AllowNonRemovable,
    # Skip every prompt and write the manifest defaults. For unattended use.
    [switch]$UseDefaults,
    # Write settings onto a card that already has this image, without
    # re-writing the image itself. This is the re-addressing path.
    [string]$ConfigureOnly
)
$ErrorActionPreference = 'Stop'

$AppName  = 'syringe-pump'
$ImageUrl = "https://github.com/stefangolas/syringe_pump/releases/download/pi-image/$AppName.img.xz"
$ShaUrl   = "$ImageUrl.sha256"
$Cache    = Join-Path $env:LOCALAPPDATA "$AppName-sdm"
$Image    = Join-Path $Cache "$AppName.img.xz"

# Defaults, kept in step with pi-image/pi-app.env. A test asserts they match,
# because this script is fetched standalone and cannot read the manifest.
$Defaults = @{
    ETH_ADDRESS = '10.194.22.184'
    ETH_PREFIX  = '24'
    ETH_GATEWAY = ''
    ETH_DNS     = ''
    PI_HOSTNAME = 'syringe-pump'
    PI_USER     = 'chorylab'
    SERVER_PORT = '5000'
    MOTORS      = 'a:22,23,17,27,25 b:5,6,13,19,26'
}
# Dropping the second entry is how a card is made single-motor.
$MotorsOne = 'a:22,23,17,27,25'

# Upper bound on what can plausibly be the SD card. SD cards for this job top
# out around 128GB and the image needs only a few; any machine doing the
# writing has far more. IsBoot and IsSystem are the guards that matter, but
# they only protect the disk you booted from -- a second internal drive is
# neither. This is what stops -DiskNumber naming one of those by mistake, so
# keep it near the top of the plausible card range rather than the disk range.
$MaxCardBytes = 130GB

function Test-IsAdmin {
    ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# Imager moves. v1 installed to 'Raspberry Pi Imager', v2 to
# 'Raspberry Pi Ltd\Imager', and a per-user install lands somewhere else
# again -- so hardcoded paths go stale and the script claims Imager is not
# installed when it plainly is. Ask Windows where it is before guessing:
# App Paths and the uninstall entry are both written by the installer and
# survive the vendor renaming its directory.
function Find-Imager {
    $cmd = Get-Command rpi-imager -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }

    $appPaths = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\rpi-imager.exe',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\rpi-imager.exe'
    )
    foreach ($key in $appPaths) {
        $entry = (Get-ItemProperty -LiteralPath $key -ErrorAction SilentlyContinue).'(default)'
        if ($entry -and (Test-Path -LiteralPath $entry)) { return $entry }
    }

    $uninstall = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    foreach ($key in $uninstall) {
        foreach ($app in (Get-ItemProperty $key -ErrorAction SilentlyContinue |
                          Where-Object { $_.DisplayName -like '*Raspberry Pi Imager*' })) {
            if (-not $app.InstallLocation) { continue }
            $exe = Join-Path $app.InstallLocation 'rpi-imager.exe'
            if (Test-Path -LiteralPath $exe) { return $exe }
        }
    }

    # Last resort: the layouts we have actually seen, newest first.
    $roots = @($env:ProgramFiles, ${env:ProgramFiles(x86)}, "$env:LOCALAPPDATA\Programs") |
             Where-Object { $_ }
    foreach ($root in $roots) {
        foreach ($leaf in @('Raspberry Pi Ltd\Imager', 'Raspberry Pi Imager')) {
            $exe = Join-Path $root (Join-Path $leaf 'rpi-imager.exe')
            if (Test-Path -LiteralPath $exe) { return $exe }
        }
    }
    return $null
}

# --- boot-partition discovery ---------------------------------------------
# The FAT partition is the one carrying cmdline.txt. Two Windows quirks make
# this harder than it looks, and both have bitten us:
#   * Get-Volume reports FileSystem inconsistently -- it can come back empty
#     for a perfectly good partition -- so filtering on 'FAT32' silently hides
#     the card. Do not filter on it; cmdline.txt is the real signal.
#   * Windows does not always assign a drive letter. Disk Management then
#     shows the volume under its "bootfs" label with the letter column blank,
#     and the only path it has is \\?\Volume{GUID}\, which both New-Item and
#     tar reject. Match those too, and assign a letter before writing.
function Find-PiBootVolume {
    $vols = @()
    try { $vols = @(Get-Volume -ErrorAction Stop | Where-Object { $_.DriveType -ne 'Remote' }) } catch {}
    foreach ($v in $vols) {
        $root = if ($v.DriveLetter) { "$($v.DriveLetter):\" } else { $v.Path }
        if ($root -and (Test-Path -LiteralPath (Join-Path $root 'cmdline.txt'))) { $v }
    }
}

# Return the volume's drive letter, assigning one first if it has none.
function Mount-PiBootVolume {
    param([Parameter(Mandatory = $true)]$Volume)
    if ($Volume.DriveLetter) { return [string]$Volume.DriveLetter }

    if (-not (Test-IsAdmin)) {
        throw @"
The card's boot partition ("$($Volume.FileSystemLabel)") has no drive letter,
so nothing can be written to it. Either:
  * re-run this from a PowerShell started with "Run as administrator", or
  * give it a letter by hand -- Win+X, Disk Management, right-click the
    "bootfs" partition, Change Drive Letter and Paths, Add, OK -- then re-run.
"@
    }

    $part = Get-Partition | Where-Object { $_.AccessPaths -contains $Volume.Path }
    if (-not $part) { throw "Could not find the partition behind $($Volume.Path)." }
    $used = (Get-Volume).DriveLetter | Where-Object { $_ }
    $free = 69..90 | ForEach-Object { [char]$_ } |
            Where-Object { $used -notcontains $_ } | Select-Object -First 1
    if (-not $free) { throw 'No free drive letters left to assign.' }

    Write-Host "Boot partition has no drive letter; assigning ${free}:"
    $part | Set-Partition -NewDriveLetter $free
    foreach ($try in 1..20) {
        if (Test-Path -LiteralPath "${free}:\cmdline.txt") { return [string]$free }
        Start-Sleep -Milliseconds 500
    }
    throw "Assigned ${free}: but the boot partition never appeared there."
}

# --- the prompt UI --------------------------------------------------------
# Every prompt shows its default in brackets and accepts Enter. Validation
# happens here as well as on the Pi: being told "that is not an IPv4 address"
# now beats discovering it when the instrument does not come up.
function Ask {
    param(
        [string]$Question,
        [string]$Default,
        [scriptblock]$Validate,
        [string]$Hint
    )
    if ($UseDefaults) { return $Default }
    while ($true) {
        $shown = if ($Default -eq '') { '<none>' } else { $Default }
        $answer = Read-Host "$Question [$shown]"
        if ([string]::IsNullOrWhiteSpace($answer)) { return $Default }
        $answer = $answer.Trim()
        # A literal "none" is how a prompt with a non-empty default is cleared,
        # since Enter means "keep it" and an empty line cannot mean both.
        if ($answer -eq 'none') { $answer = '' }
        if ($null -eq $Validate -or (& $Validate $answer)) { return $answer }
        Write-Host "  not valid$(if ($Hint) { ": $Hint" })" -ForegroundColor Yellow
    }
}

$IsIPv4 = {
    param($v)
    if ($v -eq '') { return $true }
    $parsed = [ref]([ipaddress]'0.0.0.0')
    [ipaddress]::TryParse($v, $parsed) -and $v.Split('.').Count -eq 4
}

function Read-CardSettings {
    Write-Host ''
    Write-Host 'Card settings' -ForegroundColor Cyan
    Write-Host 'Press Enter to accept the value in brackets. Type "none" to clear one.'
    Write-Host ''

    $cfg = @{}
    $cfg['ETH_ADDRESS'] = Ask 'Static IP address for the Pi' $Defaults.ETH_ADDRESS `
        { param($v) if ($v -eq '') { $false } else { & $IsIPv4 $v } } 'e.g. 10.194.22.184'
    $cfg['ETH_PREFIX'] = Ask 'Subnet prefix length' $Defaults.ETH_PREFIX `
        { param($v) ($v -match '^\d+$') -and [int]$v -ge 1 -and [int]$v -le 32 } '1-32, e.g. 24'
    Write-Host '  Leave the gateway and DNS empty for an isolated link: with no default'
    Write-Host '  route the Pi is reachable only from hosts on the same switch. The server'
    Write-Host '  has NO authentication, so on a routed LAN anyone who can reach the port'
    Write-Host '  can drive the pump.' -ForegroundColor DarkGray
    $cfg['ETH_GATEWAY'] = Ask 'Gateway (empty = isolated)' $Defaults.ETH_GATEWAY $IsIPv4 'an IPv4 address, or none'
    $cfg['ETH_DNS'] = Ask 'DNS server (empty = none)' $Defaults.ETH_DNS $IsIPv4 'an IPv4 address, or none'
    $cfg['PI_HOSTNAME'] = Ask 'Hostname' $Defaults.PI_HOSTNAME `
        { param($v) $v -match '^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$' } 'letters, digits and hyphens'
    $cfg['SERVER_PORT'] = Ask 'Server port' $Defaults.SERVER_PORT `
        { param($v) ($v -match '^\d+$') -and [int]$v -ge 1 -and [int]$v -le 65535 } '1-65535'

    Write-Host ''
    $count = Ask 'How many motors on this Pi? (1 or 2)' '2' `
        { param($v) $v -in @('1', '2') } '1 or 2'
    if ($count -eq '1') {
        $cfg['MOTORS'] = $MotorsOne
    } else {
        $cfg['MOTORS'] = $Defaults.MOTORS
    }
    Write-Host "  motors: $($cfg['MOTORS'])" -ForegroundColor DarkGray
    Write-Host '  Each motor is commanded separately at /motor/<id>/run.' -ForegroundColor DarkGray

    # --- password ---------------------------------------------------------
    # Optional: Enter leaves whatever the image was built with. Base64 because
    # this file is written by PowerShell and read by bash on the Pi, and any
    # quoting scheme that survives one can break the other.
    if (-not $UseDefaults) {
        Write-Host ''
        Write-Host "Password for the '$($Defaults.PI_USER)' account (SSH login)."
        Write-Host 'Leave BOTH blank to keep the password the image was built with.'
        $p1 = Read-Host 'Password' -AsSecureString
        $p2 = Read-Host 'Again' -AsSecureString
        $s1 = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
                [Runtime.InteropServices.Marshal]::SecureStringToBSTR($p1))
        $s2 = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
                [Runtime.InteropServices.Marshal]::SecureStringToBSTR($p2))
        if ($s1 -or $s2) {
            if ($s1 -ne $s2) { throw 'Passwords do not match.' }
            $cfg['PI_PASSWORD_B64'] = [Convert]::ToBase64String(
                [Text.Encoding]::UTF8.GetBytes($s1))
        }
    }
    return $cfg
}

function Write-CardSettings {
    param([string]$BootRoot, [hashtable]$Cfg)

    $lines = @(
        "# $AppName card settings, written by bootstrap.ps1 on $(Get-Date -Format 'yyyy-MM-dd HH:mm').",
        '#',
        '# Read on EVERY boot by /usr/local/sbin/' + $AppName + '-firstboot. Edit this file',
        '# and reboot the Pi to change any of it -- no reflash needed. A key left out',
        '# falls back to the value baked into the image.',
        '#',
        '# An invalid value is refused as a whole and nothing is applied, so a typo',
        '# cannot strand the instrument. The result is logged beside this file as',
        "# $AppName-firstboot.log."
    )
    foreach ($key in @('ETH_ADDRESS', 'ETH_PREFIX', 'ETH_GATEWAY', 'ETH_DNS',
                       'PI_HOSTNAME', 'SERVER_PORT', 'MOTORS', 'PI_SSH_PUBKEY',
                       'PI_PASSWORD_B64')) {
        if ($Cfg.ContainsKey($key)) { $lines += "$key=$($Cfg[$key])" }
    }

    # LF endings and no BOM: bash reads this file, and a BOM on the first line
    # would end up inside the first key's name.
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    $target = Join-Path $BootRoot "$AppName.conf"
    [IO.File]::WriteAllText($target, (($lines -join "`n") + "`n"), $utf8NoBom)
    Write-Host "  wrote $target"

    # Retire a log from a previous boot: it describes a configuration that is
    # no longer on the card, and reading it as current would mislead.
    $log = Join-Path $BootRoot "$AppName-firstboot.log"
    if (Test-Path -LiteralPath $log) {
        Move-Item -LiteralPath $log -Destination "$log.prev" -Force
        Write-Host "  kept the previous boot log as $AppName-firstboot.log.prev"
    }
}

function Show-Next {
    param([hashtable]$Cfg)
    $addr = $Cfg['ETH_ADDRESS']
    $port = $Cfg['SERVER_PORT']
    $user = $Defaults.PI_USER

    # The example controller address has to sit on the Pi's own subnet, so it
    # is derived rather than hardcoded -- a hardcoded one contradicts the
    # address printed above it the first time the address is changed.
    $controller = $null
    if ($addr -match '^(\d{1,3}\.\d{1,3}\.\d{1,3})\.(\d{1,3})$') {
        $last = [int]$Matches[2]
        $controller = "$($Matches[1])." + $(if ($last -eq 2) { '3' } else { '2' })
    }

    Write-Host ''
    if ($Cfg['ETH_GATEWAY']) {
        Write-Host 'Done. The Pi will join your LAN at the address above.' -ForegroundColor Green
        Write-Host 'Put the card in the Pi and switch it on.'
    } else {
        Write-Host 'Almost done. NOTHING on the Pi link hands out addresses, so this PC must' -ForegroundColor Green
        Write-Host 'be given a static address before the Pi is reachable:' -ForegroundColor Green
        Write-Host ''
        Write-Host '  1. Connect this PC to the Pi with an Ethernet cable.'
        Write-Host '  2. Find the wired adapter, then set a static address (replace "Ethernet"'
        Write-Host '     with the name Get-NetAdapter shows for the wired adapter):'
        Write-Host ''
        Write-Host '       Get-NetAdapter'
        if ($controller) {
            Write-Host "       New-NetIPAddress -InterfaceAlias Ethernet -IPAddress $controller -PrefixLength $($Cfg['ETH_PREFIX'])"
            Write-Host ''
            Write-Host "     No gateway, no DNS. Leave Wi-Fi alone for internet. Undo later with:"
            Write-Host "       Remove-NetIPAddress -InterfaceAlias Ethernet -IPAddress $controller"
        } else {
            Write-Host "     Use an address on the same subnet as $addr, with no gateway."
        }
        Write-Host ''
        Write-Host '  3. Put the card in the Pi and switch it on.'
    }
    Write-Host ''
    Write-Host '  The Pi answers at:'
    Write-Host "       API:    http://${addr}:${port}"
    Write-Host "       motors: http://${addr}:${port}/motors"
    Write-Host "       SSH:    ssh $user@$addr"
    Write-Host ''
    Write-Host "  Motors: $($Cfg['MOTORS'])"
    Write-Host "     run:  POST http://${addr}:${port}/motor/a/run   {`"steps`": 600}"
    Write-Host "     stop: POST http://${addr}:${port}/motor/a/stop"
    Write-Host ''
    Write-Host "  To change any of this later: edit $AppName.conf on the card's boot"
    Write-Host '  partition and reboot the Pi. No reflash, no rebuild.'
    if (-not $Cfg.ContainsKey('PI_PASSWORD_B64')) {
        Write-Warning "No password was set, so the image's build credential still applies."
    }
}

Write-Host ''
Write-Host "=== $AppName image flasher ===" -ForegroundColor Cyan

# --- the re-addressing path ----------------------------------------------
# Deliberately first and separate: it touches no disk except the FAT partition,
# needs no download, and needs no Imager. It is the common case once a card has
# been written once.
if ($ConfigureOnly) {
    # Accept a bare drive letter ("E" or "E:") and also a full path, so this
    # works for a volume mounted somewhere other than a letter -- and so the
    # tests can point it at a directory.
    $trimmed = $ConfigureOnly.TrimEnd([char]92, '/')
    if ($trimmed.Contains([char]92) -or $trimmed.Contains('/')) {
        $root = $trimmed
    } else {
        $root = $trimmed.TrimEnd(':') + ':' + [char]92
    }
    if (-not (Test-Path -LiteralPath (Join-Path $root 'cmdline.txt'))) {
        throw "$ConfigureOnly has no cmdline.txt - that is not a Raspberry Pi boot partition."
    }
    Write-Host "Configuring the card at $root (the image is not being rewritten)"
    $cfg = Read-CardSettings
    Write-CardSettings -BootRoot $root -Cfg $cfg
    Show-Next -Cfg $cfg
    return
}

if (-not (Test-IsAdmin)) { throw 'Open PowerShell with Run as administrator and try again.' }
$Imager = Find-Imager
if (-not $Imager) { throw 'Install Raspberry Pi Imager from https://www.raspberrypi.com/software/ and try again.' }

# Two tiers. Writable is the real safety boundary: never the disk we booted
# from, never the system disk, never something too big to be removable media.
# Autodetect narrows that further by bus, because guessing wrong unprompted is
# unforgivable -- but the bus is only a hint. Built-in PCIe card readers report
# SCSI, so an explicit -DiskNumber has to be able to reach a disk autodetect
# passed over, or the recovery path does not run on the machine you would be
# recovering from.
$Writable = @(Get-Disk | Where-Object {
    -not $_.IsBoot -and -not $_.IsSystem -and $_.Size -lt $MaxCardBytes
})
$Disks = @($Writable | Where-Object { $_.BusType -in @('USB','SD','MMC') })
if ($DiskNumber -ge 0) {
    $Disk = $Writable | Where-Object Number -eq $DiskNumber
    if (-not $Disk) {
        $limit = [math]::Round($MaxCardBytes / 1GB)
        throw "Disk $DiskNumber is not writable here: it must not be the boot or system disk, and must be under ${limit}GB."
    }
} else {
    if ($Disks.Count -eq 0) {
        # Say which disks were rejected and why, so the next person knows what
        # to pass rather than concluding the card is not detected at all.
        Write-Host ''
        Write-Host 'No removable disk found by bus type.' -ForegroundColor Yellow
        if ($Writable.Count -gt 0) {
            Write-Host 'These are writable but did not look removable:'
            foreach ($d in $Writable) {
                Write-Host "  Disk $($d.Number)  $($d.FriendlyName)  $([math]::Round($d.Size/1GB,1)) GB  (bus: $($d.BusType))"
            }
            Write-Host ''
            Write-Host 'Built-in card readers often report SCSI. If one of those is your card,'
            Write-Host 'name it explicitly, e.g.  .\bootstrap.ps1 -DiskNumber ' -NoNewline
            Write-Host "$($Writable[0].Number)"
        }
        throw 'No removable disk found.'
    }
    Write-Host ''
    for ($i = 0; $i -lt $Disks.Count; $i++) {
        $d = $Disks[$i]
        Write-Host "  [$($i+1)] Disk $($d.Number)  $($d.FriendlyName)  $([math]::Round($d.Size/1GB,1)) GB"
    }
    $choice = [int](Read-Host "Which one? [1-$($Disks.Count)]")
    if ($choice -lt 1 -or $choice -gt $Disks.Count) { throw 'Invalid selection.' }
    $Disk = $Disks[$choice - 1]
}

Write-Host ''
Write-Host "  !! Disk $($Disk.Number) ($($Disk.FriendlyName)) will be COMPLETELY ERASED" -ForegroundColor Red
if ((Read-Host '  Type ERASE to continue') -ne 'ERASE') { Write-Host 'Aborted.'; return }

# Asked BEFORE the download and the write, so the long unattended part of the
# run is the part that needs no one sitting in front of it.
$cfg = Read-CardSettings

New-Item -ItemType Directory -Force -Path $Cache | Out-Null
Write-Host ''
Write-Host '>> fetching the published checksum'
$ShaFile = Join-Path $Cache "$AppName.img.xz.sha256"
Invoke-WebRequest -Uri $ShaUrl -OutFile $ShaFile -UseBasicParsing
$Expected = ((Get-Content -Raw $ShaFile).Trim() -split '\s+')[0].ToLowerInvariant()
if ($Expected -notmatch '^[0-9a-f]{64}$') { throw 'Published checksum is invalid.' }

$NeedDownload = -not (Test-Path -LiteralPath $Image)
if (-not $NeedDownload) {
    $NeedDownload = (Get-FileHash -Algorithm SHA256 -LiteralPath $Image).Hash.ToLowerInvariant() -ne $Expected
}
if ($NeedDownload) {
    Write-Host '>> downloading the ready-to-flash image (about 1 GB)'
    Invoke-WebRequest -Uri $ImageUrl -OutFile "$Image.part" -UseBasicParsing
    Move-Item -Force "$Image.part" $Image
} else {
    Write-Host '>> using the verified cached image'
}
if ((Get-FileHash -Algorithm SHA256 -LiteralPath $Image).Hash.ToLowerInvariant() -ne $Expected) {
    throw 'Downloaded image checksum does not match the published checksum.'
}

Write-Host '>> writing and verifying the audited image'

# rpi-imager.exe is a GUI-subsystem binary, so `&` launches it and returns
# immediately. $LASTEXITCODE is then whatever the previous command left
# behind -- 0 -- so the success check passed and this script reported a card
# it had never written. Imager ships rpi-imager-cli.cmd for exactly this
# reason; that wrapper's own comment reads "necessary because it is compiled
# as GUI application, and Windows normally does not wait until those exit".
# Match Imager's own spelling of the device path.
$Target = "\\.\PhysicalDrive$($Disk.Number)"
$Before = (Get-Disk -Number $Disk.Number).Signature

# Start-Process -Wait blocks whatever the subsystem, which is the same trick
# the wrapper uses. Calling the exe directly avoids handing a path with
# spaces through cmd's quoting rules, which breaks it.
$ImagerArgs = @('--cli', $Image, $Target)
if ($AllowNonRemovable) { $ImagerArgs += '--enable-writing-system-drives' }
$proc = Start-Process -FilePath $Imager -Wait -PassThru -ArgumentList $ImagerArgs
if ($proc.ExitCode -ne 0) {
    if (-not $AllowNonRemovable) {
        Write-Host ''
        Write-Host 'If Imager said the destination is not a removable volume, that is its' -ForegroundColor Yellow
        Write-Host 'own check, not ours: built-in card readers do not report themselves as'
        Write-Host 'removable. Disk ' -NoNewline
        Write-Host $Disk.Number -NoNewline
        Write-Host ' is neither the boot nor the system disk and is under the'
        Write-Host 'card-size cap, so if you are certain it is the card, re-run with:'
        Write-Host ''
        Write-Host ('    .' + [char]92 + 'bootstrap.ps1 -DiskNumber ' + $Disk.Number + ' -AllowNonRemovable')
        Write-Host ''
    }
    throw "Raspberry Pi Imager failed with exit code $($proc.ExitCode)."
}

# Imager verifies its own write, but it cannot report a write it never
# started. Writing an image always replaces the partition table, so an
# unchanged disk signature means nothing reached the card.
$After = (Get-Disk -Number $Disk.Number).Signature
if ($Before -eq $After) {
    throw 'Raspberry Pi Imager reported success but the disk is unchanged. Nothing was written.'
}

# --- write the settings onto the card ------------------------------------
Write-Host '>> waiting for Windows to mount the boot partition'
$bootRoot = $null
for ($i = 0; $i -lt 30; $i++) {
    Start-Sleep -Seconds 2
    $v = @(Find-PiBootVolume)
    if ($v.Count -gt 0) {
        $bootRoot = (Mount-PiBootVolume -Volume $v[0]) + ':' + [char]92
        break
    }
}
if (-not $bootRoot) {
    # The image is on the card and is usable with its baked defaults, so this
    # is recoverable without rewriting a gigabyte. Say exactly how.
    Write-Warning 'The image was written but Windows did not mount the boot partition,'
    Write-Warning 'so the settings could not be saved to the card. The Pi will come up on'
    Write-Warning "the built-in defaults ($($Defaults.ETH_ADDRESS)). Re-insert the card and run:"
    Write-Warning '    .\bootstrap.ps1 -ConfigureOnly E:'
    return
}
Write-Host ">> saving the card's settings"
Write-CardSettings -BootRoot $bootRoot -Cfg $cfg

Show-Next -Cfg $cfg
