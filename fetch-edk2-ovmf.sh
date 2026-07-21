#!/bin/sh
set -eu

url=https://github.com/osdev0/edk2-ovmf-nightly/releases/download/20260531T041444Z/edk2-ovmf.tar.xz
firmware_dir=${EDK2_OVMF_DIR:-dist/qemu/firmware}
install_dir="$firmware_dir/edk2-ovmf-nightly"
marker="$firmware_dir/.edk2-ovmf-url"

mkdir -p "$firmware_dir"
if [ -f "$marker" ] && [ "$(cat "$marker")" = "$url" ] &&
    [ -f "$install_dir/x64/code.fd" ] && [ -f "$install_dir/x64/vars.fd" ]; then
    echo "EDK2 OVMF firmware is already present: $install_dir"
    exit 0
fi

tmp_dir=$(mktemp -d)
trap 'rm -rf "$tmp_dir"' EXIT

archive="$tmp_dir/edk2-ovmf.tar.xz"
echo "Fetching EDK2 OVMF firmware..."
curl --fail --location --retry 3 --output "$archive" "$url"

mkdir "$tmp_dir/extracted"
tar -xJf "$archive" -C "$tmp_dir/extracted"
code_source=$(find "$tmp_dir/extracted" -type f -name 'ovmf-code-x86_64.fd' -print -quit)
vars_source=$(find "$tmp_dir/extracted" -type f -name 'ovmf-vars-x86_64.fd' -print -quit)
[ -n "$code_source" ] || { echo "downloaded archive has no x86_64 OVMF code image" >&2; exit 1; }
[ -n "$vars_source" ] || { echo "downloaded archive has no x86_64 OVMF vars image" >&2; exit 1; }

rm -rf "$install_dir"
mkdir -p "$install_dir/x64"
cp "$code_source" "$install_dir/x64/code.fd"
cp "$vars_source" "$install_dir/x64/vars.fd"
cp "$archive" "$firmware_dir/edk2-ovmf.tar.xz"
printf '%s\n' "$url" > "$marker"
echo "Installed EDK2 OVMF firmware: $install_dir"
