#!/bin/sh

log=/tmp/fetch.log
probe_output=/tmp/fetch-command.$$

mkdir -p /tmp
: > "$log" || {
    echo "cannot write diagnostic log: $log" >&2
    exit 1
}

section() {
    printf '\n===== %s =====\n' "$1"
}

run() {
    printf '\n$'
    printf ' %s' "$@"
    printf '\n'
    "$@" 2>&1 || printf 'command exited with status %s\n' "$?"
}

dump() {
    file=$1
    printf '\n--- %s ---\n' "$file"
    if [ -r "$file" ]; then
        sed -n '1,4000p' "$file"
    else
        printf 'unavailable\n'
    fi
}

list_dir() {
    dir=$1
    printf '\n--- %s ---\n' "$dir"
    if [ -d "$dir" ]; then
        find "$dir" -maxdepth 2 -mindepth 1 -print 2>&1 | sort
    else
        printf 'unavailable\n'
    fi
}

probe() {
    if command -v "$1" >"$probe_output" 2>&1; then
        run "$@"
    else
        printf '\n$'
        printf ' %s' "$@"
        printf '\nnot installed\n'
    fi
}

collect() {
    section 'identity and environment'
    run date -u
    run hostname
    run id
    run uname -a
    run uptime
    dump /etc/alpine-release
    dump /etc/hostname
    dump /etc/os-release
    dump /etc/profile.d/home-installer.sh
    run env

    section 'boot and kernel'
    dump /proc/cmdline
    dump /proc/version
    dump /proc/sys/kernel/tainted
    probe dmesg
    dump /var/log/messages
    dump /var/log/dmesg
    probe lsmod
    probe modinfo i915
    probe modinfo snd_hda_intel
    probe modinfo snd_sof_pci_intel_tgl
    probe modinfo snd_sof_pci
    probe rc-status -a
    probe rc-update show

    section 'cpu memory and power'
    dump /proc/cpuinfo
    dump /proc/meminfo
    dump /sys/devices/system/cpu/cpu0/cpufreq/scaling_driver
    dump /sys/devices/system/cpu/cpu0/cpufreq/scaling_available_governors
    dump /sys/power/mem_sleep
    dump /sys/power/state
    list_dir /sys/class/power_supply

    section 'firmware and boot mode'
    list_dir /sys/firmware/efi
    probe efibootmgr -v
    for file in /sys/firmware/efi/efivars/SecureBoot-* /sys/firmware/efi/efivars/SetupMode-*; do
        [ -f "$file" ] || continue
        printf '\n--- %s ---\n' "$file"
        od -An -t u1 "$file" 2>&1 || true
    done

    section 'pci devices and drivers'
    probe lspci -nnk
    for device in /sys/bus/pci/devices/*; do
        [ -d "$device" ] || continue
        printf '\n%s\n' "$device"
        for file in vendor device class subsystem_vendor subsystem_device modalias; do
            [ -r "$device/$file" ] && printf '%s=%s\n' "$file" "$(cat "$device/$file")"
        done
        if [ -L "$device/driver" ]; then
            printf 'driver=%s\n' "$(readlink "$device/driver")"
        fi
    done

    section 'usb devices'
    probe lsusb
    list_dir /sys/bus/usb/devices

    section 'storage and filesystems'
    probe lsblk -a -o NAME,PATH,MODEL,SERIAL,SIZE,TYPE,FSTYPE,LABEL,UUID,MOUNTPOINTS
    probe blkid
    probe findmnt -A
    run df -hT
    dump /etc/fstab

    section 'network and wireless'
    probe ip address show
    probe ip link show
    probe ip route show
    probe ip -6 route show
    probe iw dev
    probe iw list
    probe wpa_cli -i wlan0 status
    for iface in /sys/class/net/*; do
        [ -d "$iface" ] || continue
        name=${iface##*/}
        printf '\n--- interface %s ---\n' "$name"
        for file in address operstate carrier mtu speed type; do
            [ -r "$iface/$file" ] && printf '%s=%s\n' "$file" "$(cat "$iface/$file")"
        done
        [ -d "$iface/wireless" ] && printf 'wireless=yes\n'
        [ -L "$iface/device/driver" ] && printf 'driver=%s\n' "$(readlink "$iface/device/driver")"
    done
    dump /etc/network/interfaces
    printf '\n--- /etc/wpa_supplicant/wpa_supplicant.conf (secrets redacted) ---\n'
    if [ -r /etc/wpa_supplicant/wpa_supplicant.conf ]; then
        sed -E 's/^([[:space:]]*(psk|password)=).*/\1<redacted>/' /etc/wpa_supplicant/wpa_supplicant.conf
    else
        printf 'unavailable\n'
    fi
    probe rc-service networking status
    probe rc-service wpa_supplicant status

    section 'display graphics and acceleration'
    list_dir /sys/class/drm
    for connector in /sys/class/drm/card*-*; do
        [ -d "$connector" ] || continue
        printf '\n--- %s ---\n' "$connector"
        for file in status enabled modes dpms; do
            [ -r "$connector/$file" ] && printf '%s:\n%s\n' "$file" "$(cat "$connector/$file")"
        done
    done
    probe vainfo
    probe glxinfo -B
    probe weston-info
    probe seatd -v
    probe modinfo i915
    dump /sys/module/i915/parameters/enable_psr
    dump /sys/module/i915/parameters/enable_fbc
    dump /sys/module/i915/parameters/enable_guc

    section 'audio'
    dump /proc/asound/cards
    dump /proc/asound/devices
    dump /proc/asound/version
    list_dir /sys/class/sound
    probe aplay -l
    probe amixer -c 0 info
    probe modinfo snd_hda_intel
    probe modinfo snd_hda_codec_hdmi
    probe modinfo snd_sof_pci_intel_tgl
    probe modinfo snd_sof_pci

    section 'alpine packages and configuration'
    probe apk info
    dump /etc/apk/world
    dump /etc/apk/repositories
    dump /etc/inittab
    probe rc-status
    probe rc-update show
    dump /etc/adjtime
    run readlink /etc/localtime
    run locale
    dump /etc/resolv.conf

    section 'recent logs'
    for file in /var/log/*; do
        [ -f "$file" ] || continue
        printf '\n--- tail %s ---\n' "$file"
        tail -200 "$file" 2>&1 || true
    done

    section 'diagnostic summary'
    printf 'log=%s\n' "$log"
    printf 'collected_at=%s\n' "$(date -u)"
    printf 'Attach %s when reporting hardware problems.\n' "$log"
}

collect 2>&1 | tee "$log"
rm -f "$probe_output"
