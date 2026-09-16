#!/bin/sh
set -eu

url=https://github.com/osdev0/edk2-ovmf-nightly/releases/download/20260531T041444Z/edk2-ovmf.tar.xz
sha256=5aa3e4b3abed958c15f39067aa7a397469d4ea277afbd4f9f77d52472b0197bd
repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
firmware_root=$repo_dir/dist/qemu/firmware
firmware_dir=${EDK2_OVMF_DIR:-$firmware_root}
case $firmware_dir in
    /*) ;;
    *) firmware_dir=$repo_dir/$firmware_dir ;;
esac
case $firmware_dir in
    "$firmware_root"|"$firmware_root"/*) ;;
    *) echo 'EDK2_OVMF_DIR must be beneath dist/qemu/firmware' >&2; exit 1 ;;
esac
case $firmware_dir in
    *'/../'*|*/..|../*|..)
        echo 'EDK2_OVMF_DIR must not contain parent-directory components' >&2
        exit 1
        ;;
esac
install_dir="$firmware_dir/edk2-ovmf-nightly"
marker="$firmware_dir/.edk2-ovmf-url"

ensure_directory() {
    directory=$1
    [ ! -L "$directory" ] || {
        echo "refusing symlink directory: $directory" >&2
        exit 1
    }
    if [ -e "$directory" ]; then
        [ -d "$directory" ] || {
            echo "refusing non-directory path: $directory" >&2
            exit 1
        }
    else
        mkdir "$directory"
    fi
}

ensure_directory "$repo_dir/dist"
ensure_directory "$repo_dir/dist/qemu"
ensure_directory "$firmware_root"
current=$firmware_root
relative=${firmware_dir#"$firmware_root"}
old_ifs=$IFS
IFS=/
set -f
for component in $relative; do
    [ -n "$component" ] || continue
    [ "$component" != . ] || continue
    current=$current/$component
    ensure_directory "$current"
done
IFS=$old_ifs
set +f

[ ! -L "$install_dir" ] || {
    echo "refusing symlink installation directory: $install_dir" >&2
    exit 1
}
if [ -e "$install_dir" ]; then
    [ -d "$install_dir" ] || {
        echo "refusing non-directory installation target: $install_dir" >&2
        exit 1
    }
fi
[ ! -L "$firmware_dir/edk2-ovmf.tar.xz" ] || {
    echo "refusing symlink archive target" >&2
    exit 1
}
[ ! -L "$marker" ] || {
    echo "refusing symlink marker target" >&2
    exit 1
}

sha256_file() {
    if command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$1" | awk '{print $1}'
    else
        sha256sum "$1" | awk '{print $1}'
    fi
}

mkdir -p "$firmware_dir"
if [ -f "$marker" ] && [ "$(sed -n '1p' "$marker")" = "$url" ] &&
    [ "$(sed -n '2p' "$marker")" = "$sha256" ] &&
    [ -f "$firmware_dir/edk2-ovmf.tar.xz" ] &&
    [ "$(sha256_file "$firmware_dir/edk2-ovmf.tar.xz")" = "$sha256" ] &&
    [ -f "$install_dir/x64/code.fd" ] && [ -f "$install_dir/x64/vars.fd" ]; then
    echo "EDK2 OVMF firmware is already present: $install_dir"
    exit 0
fi

tmp_dir=$(mktemp -d)
trap 'rm -rf "$tmp_dir"' EXIT

archive="$tmp_dir/edk2-ovmf.tar.xz"
echo "Fetching EDK2 OVMF firmware..."
curl --fail --location --retry 3 --output "$archive" "$url"
[ "$(sha256_file "$archive")" = "$sha256" ] || {
    echo "downloaded OVMF archive failed SHA256 verification" >&2
    exit 1
}

mkdir "$tmp_dir/extracted"
tar -xJf "$archive" -C "$tmp_dir/extracted"
code_source=$(find "$tmp_dir/extracted" -type f -name 'ovmf-code-x86_64.fd' -print -quit)
vars_source=$(find "$tmp_dir/extracted" -type f -name 'ovmf-vars-x86_64.fd' -print -quit)
[ -n "$code_source" ] || { echo "downloaded archive has no x86_64 OVMF code image" >&2; exit 1; }
[ -n "$vars_source" ] || { echo "downloaded archive has no x86_64 OVMF vars image" >&2; exit 1; }

rm -rf -- "$install_dir"
mkdir -p "$install_dir/x64"
cp "$code_source" "$install_dir/x64/code.fd"
cp "$vars_source" "$install_dir/x64/vars.fd"
cp "$archive" "$firmware_dir/edk2-ovmf.tar.xz"
printf '%s\n%s\n' "$url" "$sha256" > "$marker"
echo "Installed EDK2 OVMF firmware: $install_dir"
