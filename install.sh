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
echo "To make it your login shell, run: chsh -s $install_dir/zs"
echo "(chsh requires $install_dir/zs to be listed in /etc/shells)"
