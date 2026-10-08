#!/usr/bin/env bash
set -euo pipefail

install_dir="${ZS_INSTALL_DIR:-/usr/local/bin}"
root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if ! command -v zig >/dev/null 2>&1; then
    echo "install.sh: zig is required to build zs" >&2
    exit 1
fi

echo "Building zs..."
(cd "$root" && zig build -Doptimize=ReleaseSafe)

binary="$root/zig-out/bin/zs"
if [ ! -x "$binary" ]; then
    echo "install.sh: build did not produce $binary" >&2
    exit 1
fi

run=()
if { ! mkdir -p "$install_dir" 2>/dev/null || [ ! -w "$install_dir" ]; } && [ "$(id -u)" -ne 0 ]; then
    run=(sudo)
fi

echo "Installing to $install_dir/zs..."
"${run[@]}" install -d "$install_dir"
"${run[@]}" install -m 755 "$binary" "$install_dir/zs"

echo "Installed $install_dir/zs"

shells_file="${ZS_SHELLS_FILE:-/etc/shells}"
if ! grep -qxF "$install_dir/zs" "$shells_file" 2>/dev/null; then
    add_entry=no
    if [ -t 0 ]; then
        read -r -p "Add $install_dir/zs to $shells_file (required by chsh)? [y/N] " answer || answer=""
        case "$answer" in
            [yY] | [yY][eE][sS]) add_entry=yes ;;
        esac
    fi
    if [ "$add_entry" = yes ]; then
        shells_run=()
        if [ ! -w "$shells_file" ] && [ "$(id -u)" -ne 0 ]; then
            shells_run=(sudo)
        fi
        echo "$install_dir/zs" | "${shells_run[@]}" tee -a "$shells_file" >/dev/null
        echo "Added $install_dir/zs to $shells_file"
    else
        echo "chsh requires $install_dir/zs to be listed in $shells_file. To add it, run:"
        echo "  echo $install_dir/zs | sudo tee -a $shells_file"
    fi
fi

echo "To make it your login shell, run: chsh -s $install_dir/zs"
