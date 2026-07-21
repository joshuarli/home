#!/bin/sh
set -eu

log=${1:?serial log path is required}

awk '
/===== identity and environment =====/ { collecting=1 }
collecting { print }
/QEMU diagnostics fixture passed\./ { exit }
' "$log" |
tr -d '\r' |
awk '
/--- \/proc\/meminfo ---/ { in_meminfo=1 }
/^--- / && $0 !~ /--- \/proc\/meminfo ---/ { in_meminfo=0 }
in_meminfo && $0 !~ /^MemTotal:/ && $0 ~ /^[^:]+:/ {
    sub(/[0-9]+( kB)?$/, "<value>")
}
{ print }
' |
sed -E \
    -e 's/^\[[[:space:]]*[0-9]+\.[0-9]+\] /[time] /' \
    -e 's/[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}/<timestamp>/g' \
    -e 's/^collected_at=.*/collected_at=<date>/' \
    -e 's/^[A-Z][a-z][a-z] [A-Z][a-z][a-z] [ 0-9][ 0-9] [0-9][0-9]:[0-9][0-9]:[0-9][0-9] UTC [0-9][0-9][0-9][0-9]$/<date>/' \
    -e 's/^ [0-9:]+ up .*$/<uptime>/' \
    -e 's/^load average: .*/load average: <load average>/' \
    -e '/calibrate_delay_direct\(\)/d' \
    -e 's/^\[time\] Memory: .*/[time] Memory: <memory>/' \
    -e 's/^\[time\] rtc_cmos .* setting system clock to .*/[time] rtc_cmos <system clock>/' \
    -e 's/^\[time\] sched_clock: .*/[time] sched_clock: <calibration>/' \
    -e 's/^\[time\] tsc: Detected .* processor$/[time] tsc: Detected <frequency> processor/' \
    -e 's/^\[time\] clocksource: tsc-early: .*/[time] clocksource: tsc-early: <calibration>/' \
    -e 's/^\[time\] Calibrating delay loop .*$/[time] Calibrating delay loop <calibration>/' \
    -e 's/^(cpu MHz|bogomips)[[:space:]]*:.*/\1: <dynamic>/' \
    -e '/^\[time\] input: /d' \
    -e 's/input\/input[0-9]+/input\/\<id\>/g' \
    -e '/^\[time\] FAT-fs .*utf8 is not/d' \
    -e '/^\[time\] \/dev\/vda[12]: Can.t open blockdev$/d' \
    -e 's/(audit\()[0-9.]+:/\1<event>:/' \
    -e 's/(RC_(RUNSCRIPT_|OPENRC_)?PID=)[0-9]+/\1<pid>/g' \
    -e 's/([[:space:]]|=)[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}([[:space:]]|$)/\1<uuid>\2/g' \
    -e 's/([[:space:]]|=)([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}([[:space:]]|$)/\1<mac>\3/g' \
    -e 's/0x[0-9a-fA-F]+/<address>/g' \
    -e 's/([0-9a-fA-F:]*:5054:ff:fe)[0-9a-fA-F]{4}/<ipv6>/g' \
    -e 's/(alpine-home 3\.24\.1 x86_64 )[0-9-]+/\1<iso-date>/' \
    -e 's/^[A-Z][a-z][a-z] ([A-Z][a-z][a-z] )?[ 0-9][ 0-9] [0-9:]+ home-installer /<syslog> /' \
    -e 's/(starting pid )[0-9]+/\1<pid>/' \
    -e 's/(networking\[)[0-9]+/\1<pid>/' \
    -e 's/(valid_lft|preferred_lft|expires) [0-9]+sec/\1 <lifetime>/g' \
    -e 's/([0-9]+\.[0-9]+) BogoMIPS/<bogomips> BogoMIPS/g' \
    -e 's/[0-9]+\.[0-9]+xD/<speed>/g' \
    -e 's/[[:space:]]+$//'
