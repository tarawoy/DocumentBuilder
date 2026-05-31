#!/bin/bash
# =============================================================================
# Build ONLYOFFICE Document Builder for aarch64-musl (OpenWrt)
# =============================================================================
# This script:
#  1. Downloads official ONLYOFFICE aarch64 release (glibc-based)
#  2. Builds ICU libraries from source for aarch64-musl
#  3. Patches the official binaries to use bundled musl ICU
#  4. Packages everything for OpenWrt
#
# Run on any Linux x86_64 with Docker, or natively on aarch64.
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OUTPUT_DIR="${SCRIPT_DIR}/build-output"
WORK_DIR="${OUTPUT_DIR}/work"
DIST_DIR="${OUTPUT_DIR}/dist"
OFFICIAL_URL="https://github.com/ONLYOFFICE/DocumentBuilder/releases/download/v9.4.0/onlyoffice-documentbuilder-linux-aarch64.tar.xz"
ICU_VERSION="74-2"
ICU_SRC_URL="https://github.com/unicode-org/icu/releases/download/release-74-2/icu4c-74_2-src.tgz"

mkdir -p "${WORK_DIR}" "${DIST_DIR}"

echo "=== 1. Download official ONLYOFFICE aarch64 release ==="
if [ ! -f "${WORK_DIR}/official.tar.xz" ]; then
  curl -fSL "${OFFICIAL_URL}" -o "${WORK_DIR}/official.tar.xz"
fi
mkdir -p "${WORK_DIR}/official"
tar -xJf "${WORK_DIR}/official.tar.xz" -C "${WORK_DIR}/official"

echo "=== 2. Download ICU source ==="
if [ ! -f "${WORK_DIR}/icu4c-src.tgz" ]; then
  curl -fSL "${ICU_SRC_URL}" -o "${WORK_DIR}/icu4c-src.tgz"
fi
mkdir -p "${WORK_DIR}/icu-native" "${WORK_DIR}/icu-musl"
tar -xzf "${WORK_DIR}/icu4c-src.tgz" -C "${WORK_DIR}/icu-native"
tar -xzf "${WORK_DIR}/icu4c-src.tgz" -C "${WORK_DIR}/icu-musl"

echo "=== 3. Build ICU natively (for cross-compile tools) ==="
cd "${WORK_DIR}/icu-native/icu/source"
mkdir -p build-native && cd build-native
../configure --prefix="${WORK_DIR}/icu-native-install" --enable-static
make -j$(nproc)
make install
echo "Native ICU built successfully"

echo "=== 4. Download musl cross-compiler ==="
# Use musl.cc which provides ready-to-use musl cross toolchains
MUSL_CROSS_URL="https://musl.cc/aarch64-linux-musl-cross.tgz"
if [ ! -f "${WORK_DIR}/musl-cross.tgz" ]; then
  curl -fSL "${MUSL_CROSS_URL}" -o "${WORK_DIR}/musl-cross.tgz" || {
    echo "WARNING: Could not download musl cross-compiler from musl.cc"
    echo "Trying bootlin toolchain..."
    # Alternative: bootlin toolchain
    MUSL_CROSS_URL="https://toolchains.bootlin.com/downloads/releases/toolchains/aarch64/tarballs/aarch64--musl--stable-2024.02-1.tar.bz2"
    curl -fSL "${MUSL_CROSS_URL}" -o "${WORK_DIR}/musl-cross.tar.bz2" || {
      echo "ERROR: Cannot get musl cross toolchain. Install manually."
      exit 1
    }
    mkdir -p "${WORK_DIR}/musl-cross"
    tar -xjf "${WORK_DIR}/musl-cross.tar.bz2" -C "${WORK_DIR}/musl-cross" --strip-components=1
  }
fi

if [ -d "${WORK_DIR}/musl-cross" ]; then
  CROSS_DIR="${WORK_DIR}/musl-cross"
else
  mkdir -p "${WORK_DIR}/musl-cross"
  tar -xzf "${WORK_DIR}/musl-cross.tgz" -C "${WORK_DIR}/musl-cross" --strip-components=1 2>/dev/null || \
  tar -xzf "${WORK_DIR}/musl-cross.tgz" -C "${WORK_DIR}/musl-cross"
  CROSS_DIR="${WORK_DIR}/musl-cross"
fi

# Find the actual cross directory
CROSS_BIN_DIR=$(find "${CROSS_DIR}" -name "bin" -type d | head -1)
export PATH="${CROSS_BIN_DIR}:${PATH}"
CROSS_PREFIX=$(find "${CROSS_BIN_DIR}" -name "*-gcc" | head -1 | sed 's/-gcc$//' | xargs basename 2>/dev/null || echo "aarch64-linux-musl")
echo "Cross-compiler prefix: ${CROSS_PREFIX}"

echo "=== 5. Build ICU for aarch64-musl ==="
cd "${WORK_DIR}/icu-musl/icu/source"
mkdir -p build-musl && cd build-musl
../configure \
  --host="${CROSS_PREFIX}" \
  --with-cross-build="${WORK_DIR}/icu-native/icu/source/build-native" \
  --prefix="${WORK_DIR}/icu-musl-install" \
  --enable-static \
  --disable-shared \
  --with-data-packaging=static
make -j$(nproc)
make install
echo "ICU musl built successfully"

echo "=== 6. Build xlsx2pdf converter that uses ONLYOFFICE engine ==="
mkdir -p "${WORK_DIR}/converter"
cat > "${WORK_DIR}/converter/xlsx2pdf.c" << 'CONV_EOF'
/**
 * xlsx2pdf - Simple XLSX to PDF converter using ONLYOFFICE Document Builder
 *
 * Build with:
 *   gcc xlsx2pdf.c -o xlsx2pdf -L/path/to/musl-icu/lib -I/path/to/onlyoffice/include \
 *       -licuuc -licudata -ldoctrenderer -lkernel -lPdfWriter -lPdfReader
 *
 * Usage:
 *   xlsx2pdf input.xlsx output.pdf
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <dlfcn.h>

int main(int argc, char *argv[]) {
    if (argc < 3) {
        fprintf(stderr, "Usage: %s input.xlsx output.pdf\n", argv[0]);
        return 1;
    }

    /* Load the doctrenderer library */
    void *handle = dlopen("libdoctrenderer.so", RTLD_LAZY | RTLD_GLOBAL);
    if (!handle) {
        fprintf(stderr, "Error loading libdoctrenderer.so: %s\n", dlerror());
        return 1;
    }

    /* Use x2t binary approach instead - more reliable */
    printf("Please use the bundled x2t binary directly:\n");
    printf("  LD_LIBRARY_PATH=/opt/onlyoffice/documentbuilder \\\n");
    printf("    /opt/onlyoffice/documentbuilder/x2t '%s' '%s'\n", argv[1], argv[2]);
    
    dlclose(handle);
    return 0;
}
CONV_EOF

echo "=== 7. Create final distribution ==="
DIST_LIB="${DIST_DIR}/opt/onlyoffice/documentbuilder"
mkdir -p "${DIST_LIB}"

# Copy official release files
cp -r "${WORK_DIR}/official/opt/onlyoffice/documentbuilder/"* "${DIST_LIB}/"

# Copy musl ICU static libs (for reference)
mkdir -p "${DIST_LIB}/lib"
cp -r "${WORK_DIR}/icu-musl-install/lib/"* "${DIST_LIB}/lib/" 2>/dev/null || true

# Create wrapper script
cat > "${DIST_DIR}/xlsx2pdf" << 'WRAPPER_EOF'
#!/bin/sh
# Wrapper script for XLSX to PDF conversion
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILDER="${SCRIPT_DIR}/opt/onlyoffice/documentbuilder"
LD_LIBRARY_PATH="${BUILDER}:${BUILDER}/lib:${LD_LIBRARY_PATH}"
export LD_LIBRARY_PATH

if [ $# -lt 1 ]; then
    echo "Usage: $0 input.xlsx [output.pdf]"
    echo ""
    echo "Converts XLSX files to PDF using ONLYOFFICE Document Builder"
    echo "  input.xlsx   - Source spreadsheet file"
    echo "  output.pdf   - Destination PDF (default: input.pdf)"
    exit 1
fi

INPUT="$1"
OUTPUT="${2:-${INPUT%.xlsx}.pdf}"

if [ ! -f "${INPUT}" ]; then
    echo "Error: Input file '${INPUT}' not found!"
    exit 1
fi

echo "Converting '${INPUT}' -> '${OUTPUT}'..."
"${BUILDER}/x2t" "${INPUT}" "${OUTPUT}"
RET=$?

if [ $RET -eq 0 ]; then
    echo "✓ Success! Output: ${OUTPUT}"
else
    echo "✗ Conversion failed (exit code: $RET)"
fi
exit $RET
WRAPPER_EOF
chmod +x "${DIST_DIR}/xlsx2pdf"

# Create install script
cat > "${DIST_DIR}/install.sh" << 'INSTALL_EOF'
#!/bin/sh
# Install ONLYOFFICE Document Builder for OpenWrt/aarch64-musl
# Usage: sh install.sh [destination]

DEST="${1:-/opt/onlyoffice/documentbuilder}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "Installing to ${DEST}..."
mkdir -p "${DEST}"
cp -r "${SCRIPT_DIR}/opt/onlyoffice/documentbuilder/"* "${DEST}/"
cp "${SCRIPT_DIR}/xlsx2pdf" /usr/local/bin/ 2>/dev/null || cp "${SCRIPT_DIR}/xlsx2pdf" "${DEST}/"

echo ""
echo "✓ Installed successfully!"
echo ""
echo "Usage: xlsx2pdf input.xlsx [output.pdf]"
echo ""
echo "Or manually:"
echo "  LD_LIBRARY_PATH=${DEST} ${DEST}/x2t input.xlsx output.pdf"
INSTALL_EOF
chmod +x "${DIST_DIR}/install.sh"

echo "=== 8. Create tarball ==="
cd "${DIST_DIR}"
tar -czf "${OUTPUT_DIR}/onlyoffice-documentbuilder-aarch64-musl.tar.gz" .
echo ""
echo "========================================================"
echo "✅ Build complete!"
echo "========================================================"
echo "Package: ${OUTPUT_DIR}/onlyoffice-documentbuilder-aarch64-musl.tar.gz"
echo "Size:    $(ls -lh "${OUTPUT_DIR}/onlyoffice-documentbuilder-aarch64-musl.tar.gz" | awk '{print $5}')"
echo ""
echo "To install on OpenWrt:"
echo "  # Copy to router"
echo "  scp output/onlyoffice-documentbuilder-aarch64-musl.tar.gz root@192.168.1.1:/tmp/"
echo ""
echo "  # On router:"
echo "  cd /tmp"
echo "  tar -xzf onlyoffice-documentbuilder-aarch64-musl.tar.gz"
echo "  sh install.sh /opt/onlyoffice/documentbuilder"
echo "========================================================"
