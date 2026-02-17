#!/bin/bash
# build_fatio.sh - Build fat_io_lib as a static library for macOS
# OWNER: WP3 - Only WP3 may modify this file.

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

echo "Building fat_io_lib for macOS (Universal Binary)..."

# Clean previous build
rm -f *.o libfat_io.a

# Compile all .c files as universal binary (arm64 + x86_64)
for src in *.c; do
    echo "  Compiling $src..."
    clang -c -arch arm64 -arch x86_64 -O2 -I include/ "$src" -o "${src%.c}.o"
done

# Create static library
libtool -static -o libfat_io.a *.o

echo "Built libfat_io.a successfully."
ls -la libfat_io.a

# Clean object files
rm -f *.o

echo "Done."
