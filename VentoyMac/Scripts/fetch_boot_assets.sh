#!/bin/bash
# fetch_boot_assets.sh - Download and organize Ventoy boot assets
# OWNER: WP3 - Only WP3 may modify this file.
#
# This script:
# 1. Downloads the latest Ventoy release from GitHub
# 2. Extracts ventoy.disk.img.xz (not in source repo)
# 3. Copies boot assets from our local repo clone
# 4. Organizes everything into Resources/ventoy_boot/

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
VENTOY_REPO="/Users/richardbrown/dev/ventoy/Ventoy"
BOOT_DIR="$PROJECT_DIR/VentoyMac/Resources/ventoy_boot"

# Create output directories
mkdir -p "$BOOT_DIR/boot"
mkdir -p "$BOOT_DIR/ventoy"
mkdir -p "$BOOT_DIR/EFI/BOOT"

echo "=== Fetching Ventoy Boot Assets ==="

# Step 1: Get latest release info from GitHub
echo "Checking latest Ventoy release..."
RELEASE_JSON=$(curl -s "https://api.github.com/repos/ventoy/Ventoy/releases/latest")
TAG=$(echo "$RELEASE_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin)['tag_name'])" 2>/dev/null || echo "v1.1.05")
VERSION="${TAG#v}"
echo "Latest version: $VERSION"

# Step 2: Download Linux release tarball (contains ventoy.disk.img.xz)
TARBALL_URL="https://github.com/ventoy/Ventoy/releases/download/${TAG}/ventoy-${VERSION}-linux.tar.gz"
TMPDIR=$(mktemp -d)
echo "Downloading ${TARBALL_URL}..."
curl -L -o "$TMPDIR/ventoy-linux.tar.gz" "$TARBALL_URL"

# Step 3: Extract ventoy.disk.img.xz from the tarball
echo "Extracting ventoy.disk.img.xz..."
cd "$TMPDIR"
tar xzf ventoy-linux.tar.gz
# Find ventoy.disk.img.xz in the extracted files
DISK_IMG=$(find . -name "ventoy.disk.img.xz" -type f | head -1)
if [ -z "$DISK_IMG" ]; then
    echo "ERROR: ventoy.disk.img.xz not found in release tarball!"
    rm -rf "$TMPDIR"
    exit 1
fi
cp "$DISK_IMG" "$BOOT_DIR/ventoy/ventoy.disk.img.xz"
echo "  Copied ventoy.disk.img.xz"

# Step 4: Copy boot assets from local repo
echo "Copying boot assets from repo..."

# boot.img and core.img
cp "$VENTOY_REPO/INSTALL/grub/i386-pc/boot.img" "$BOOT_DIR/boot/"
cp "$VENTOY_REPO/INSTALL/grub/i386-pc/core.img" "$BOOT_DIR/boot/"
echo "  Copied boot.img, core.img"

# EFI boot files
if [ -d "$VENTOY_REPO/INSTALL/EFI/BOOT" ]; then
    cp -R "$VENTOY_REPO/INSTALL/EFI/BOOT/"* "$BOOT_DIR/EFI/BOOT/"
    echo "  Copied EFI/BOOT files"
fi

# Ventoy EFI binaries
for efi in "$VENTOY_REPO/INSTALL/ventoy/"*.efi; do
    [ -f "$efi" ] && cp "$efi" "$BOOT_DIR/ventoy/"
done
echo "  Copied Ventoy EFI binaries"

# Step 5: Create version file
echo "$VERSION" > "$BOOT_DIR/ventoy/version"
echo "  Created version file: $VERSION"

# Cleanup
rm -rf "$TMPDIR"

echo ""
echo "=== Boot Assets Complete ==="
echo "Output directory: $BOOT_DIR"
ls -lR "$BOOT_DIR"
