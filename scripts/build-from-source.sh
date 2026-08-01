#!/bin/bash
# Build a single package from the PKGBUILDs-pipa source tree (maakiopus).
#
# PKGBUILDs-pipa is the original upstream source these device packages trace
# back to. Both binary repos this image builder uses (pipa-pkgs, pipa-alarm)
# are built from PKGBUILD trees descended from it. Use this script when a
# package you need is missing or stale in both binary repos.
#
# Usage: ./scripts/build-from-source.sh <pkgdir> [<local-repo-dir>]
#
# Example:
#   ./scripts/build-from-source.sh box64
#   ./scripts/build-from-source.sh linux-pipa /path/to/PKGBUILDs-pipa
#
# Must be run on aarch64 (or under qemu-user-static binfmt on x86_64) since
# these are ARM64 device packages. Produces a .pkg.tar.xz next to itself
# which you can then install with `pacman -U` into the rootfs, or drop into
# a local pacman repo directory and point PIPA_PKGS_REPO_URL / a custom repo
# section at it.
set -euo pipefail

PKGBUILDS_PIPA_URL="https://github.com/maakiopus/PKGBUILDs-pipa.git"

PKG="${1:?Usage: $0 <pkgdir> [<local-repo-dir>]}"
REPO_DIR="${2:-}"

if [ -z "$REPO_DIR" ]; then
    REPO_DIR="$(mktemp -d)"
    echo "### Cloning PKGBUILDs-pipa..."
    git clone --depth 1 "$PKGBUILDS_PIPA_URL" "$REPO_DIR"
fi

if [ ! -d "$REPO_DIR/$PKG" ]; then
    echo "No such package directory in PKGBUILDs-pipa: $PKG" >&2
    echo "Available packages:" >&2
    find "$REPO_DIR" -maxdepth 1 -mindepth 1 -type d -printf '  %f\n' | sort >&2
    exit 1
fi

echo "### Building $PKG from source..."
pushd "$REPO_DIR/$PKG" > /dev/null
makepkg -sf --noconfirm
popd > /dev/null

echo "### Built package(s):"
find "$REPO_DIR/$PKG" -maxdepth 1 -name '*.pkg.tar.*'
