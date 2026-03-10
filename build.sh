#!/bin/bash
#
# build.sh - Build the btrfs-snapshots Unraid plugin package
#
# Usage: ./build.sh <version>
# Example: ./build.sh 2026.03.09
#

set -euo pipefail

PLUGIN="btrfs-snapshots"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC_DIR="${SCRIPT_DIR}/src"
BUILD_DIR="${SCRIPT_DIR}/build"
PLG_FILE="${SCRIPT_DIR}/${PLUGIN}.plg"

# ── Argument validation ──────────────────────────────────────────────────────

if [ $# -lt 1 ]; then
    echo "Usage: $0 <version>"
    echo "Example: $0 2026.03.09"
    exit 1
fi

VERSION="$1"
PKG_NAME="${PLUGIN}-${VERSION}"
TXZ_FILE="${BUILD_DIR}/${PKG_NAME}.txz"

echo "============================================"
echo "  Building ${PLUGIN} v${VERSION}"
echo "============================================"
echo ""

# ── Validate source directory ────────────────────────────────────────────────

if [ ! -d "$SRC_DIR" ]; then
    echo "ERROR: Source directory not found: ${SRC_DIR}"
    exit 1
fi

if [ ! -d "${SRC_DIR}/usr" ]; then
    echo "ERROR: Source directory missing usr/ tree: ${SRC_DIR}/usr"
    exit 1
fi

# ── Clean and create build directory ─────────────────────────────────────────

echo "[1/5] Preparing build directory..."
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

# ── Set permissions ──────────────────────────────────────────────────────────

echo "[2/5] Setting file permissions..."

# Make scripts executable
find "${SRC_DIR}" -path "*/scripts/*" -type f -exec chmod 755 {} \;
find "${SRC_DIR}" -path "*/event/*" -type f -exec chmod 755 {} \;

# Config files should be readable
find "${SRC_DIR}" -name "*.cfg" -type f -exec chmod 644 {} \;
find "${SRC_DIR}" -name "*.php" -type f -exec chmod 644 {} \;
find "${SRC_DIR}" -name "*.css" -type f -exec chmod 644 {} \;
find "${SRC_DIR}" -name "*.js" -type f -exec chmod 644 {} \;
find "${SRC_DIR}" -name "*.page" -type f -exec chmod 644 {} \;

# ── Build the .txz package ──────────────────────────────────────────────────

echo "[3/5] Creating package ${PKG_NAME}.txz..."

if command -v makepkg &>/dev/null; then
    # Use Slackware makepkg if available (e.g., building on Unraid itself)
    echo "  Using makepkg (Slackware native)"
    cd "$SRC_DIR"
    makepkg -l y -c n "$TXZ_FILE"
    cd "$SCRIPT_DIR"
else
    # Fallback: create .txz with tar (works on any system)
    echo "  Using tar fallback (makepkg not available)"
    cd "$SRC_DIR"
    tar cJf "$TXZ_FILE" \
        --owner=root --group=root \
        --exclude='.DS_Store' \
        --exclude='._*' \
        --exclude='.gitkeep' \
        .
    cd "$SCRIPT_DIR"
fi

if [ ! -f "$TXZ_FILE" ]; then
    echo "ERROR: Package creation failed — ${TXZ_FILE} not found."
    exit 1
fi

# ── Generate checksums ───────────────────────────────────────────────────────

echo "[4/5] Generating checksums..."

cd "$BUILD_DIR"
md5sum "${PKG_NAME}.txz" > "${PKG_NAME}.md5"
sha256sum "${PKG_NAME}.txz" > "${PKG_NAME}.sha256" 2>/dev/null || true
cd "$SCRIPT_DIR"

# ── Update version in .plg file ─────────────────────────────────────────────

echo "[5/5] Updating version in ${PLUGIN}.plg..."

if [ -f "$PLG_FILE" ]; then
    # Update the version entity
    sed -i.bak "s|<!ENTITY version   \"[^\"]*\">|<!ENTITY version   \"${VERSION}\">|" "$PLG_FILE"
    rm -f "${PLG_FILE}.bak"
    echo "  Updated .plg version to ${VERSION}"
else
    echo "  WARNING: ${PLG_FILE} not found — skipping version update."
fi

# ── Build summary ────────────────────────────────────────────────────────────

PKG_SIZE=$(du -h "$TXZ_FILE" | cut -f1)
MD5_HASH=$(cat "${BUILD_DIR}/${PKG_NAME}.md5" | awk '{print $1}')

echo ""
echo "============================================"
echo "  Build Complete"
echo "============================================"
echo ""
echo "  Package:  ${TXZ_FILE}"
echo "  Size:     ${PKG_SIZE}"
echo "  MD5:      ${MD5_HASH}"
echo ""
echo "  Checksums:"
echo "    ${BUILD_DIR}/${PKG_NAME}.md5"
[ -f "${BUILD_DIR}/${PKG_NAME}.sha256" ] && echo "    ${BUILD_DIR}/${PKG_NAME}.sha256"
echo ""
echo "  Plugin:   ${PLG_FILE}"
echo "  Version:  ${VERSION}"
echo ""
echo "  Next steps:"
echo "    1. Test locally:  make install-local"
echo "    2. Create GitHub release with tag v${VERSION}"
echo "    3. Upload ${PKG_NAME}.txz and ${PKG_NAME}.md5 to the release"
echo ""
