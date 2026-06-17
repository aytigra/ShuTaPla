#!/bin/bash
#
# bundle-mpv.sh — embed libmpv and its dependency closure into the app bundle.
#
# Run as a build phase after the app binary is linked. It copies libmpv and every Homebrew
# dylib it transitively depends on (ffmpeg, libplacebo, …) into Contents/Frameworks; rewrites
# every install name to @rpath so the app loads them from inside the bundle instead of
# /opt/homebrew; and re-signs each dylib with the app's signing identity so it passes library
# validation under the hardened runtime.
#
# Video renders through the libmpv OpenGL render API, so no Vulkan loader, MoltenVK, or ICD
# manifest is bundled (the dependency walk only copies what libmpv actually links).
#
# Written for the macOS system bash (3.2): no associative arrays, no `readlink -f`.
# Set ENABLE_BUNDLE_MPV=0 in the environment to skip (e.g. for a quick syntax-only build).

set -euo pipefail

if [ "${ENABLE_BUNDLE_MPV:-1}" != "1" ]; then
    echo "note: bundle-mpv skipped (ENABLE_BUNDLE_MPV=0)"
    exit 0
fi

BREW_PREFIX="${BREW_PREFIX:-/opt/homebrew}"
MPV_LIB="$BREW_PREFIX/opt/mpv/lib/libmpv.2.dylib"

FRAMEWORKS="$BUILT_PRODUCTS_DIR/$FRAMEWORKS_FOLDER_PATH"
SIGN_IDENTITY="${EXPANDED_CODE_SIGN_IDENTITY:--}"

if [ ! -f "$MPV_LIB" ]; then
    echo "error: libmpv not found at $MPV_LIB — run 'brew install mpv'" >&2
    exit 1
fi

mkdir -p "$FRAMEWORKS"

# Purge artifacts an older MoltenVK-based build may have left in the product (incremental
# builds don't otherwise remove them).
rm -f "$FRAMEWORKS"/libMoltenVK.dylib \
      "$BUILT_PRODUCTS_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/MoltenVK_icd.json"

# Bash 3.2 has no associative arrays; track processed basenames in a space-delimited string.
PROCESSED_LIST=""
is_processed() { case " $PROCESSED_LIST " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }

sign() {
    codesign --force --options runtime --timestamp=none --sign "$SIGN_IDENTITY" "$1" >/dev/null 2>&1
}

# bundle_dylib <source-path>
# Copies one dylib into Frameworks, sets its @rpath id, recurses into its Homebrew deps,
# rewrites references to them, and signs it.
bundle_dylib() {
    local src="$1"
    local base
    base="$(basename "$src")"

    if is_processed "$base"; then
        return
    fi
    PROCESSED_LIST="$PROCESSED_LIST $base"

    local dest="$FRAMEWORKS/$base"
    cp -fL "$src" "$dest"           # -L resolves the symlink to copy the real file
    chmod u+w "$dest"
    install_name_tool -id "@rpath/$base" "$dest" 2>/dev/null || true

    # Walk this dylib's Homebrew dependencies.
    local dep depbase
    while IFS= read -r dep; do
        case "$dep" in
            "$BREW_PREFIX"/*)
                depbase="$(basename "$dep")"
                install_name_tool -change "$dep" "@rpath/$depbase" "$dest" 2>/dev/null || true
                bundle_dylib "$dep"
                ;;
        esac
    done < <(otool -L "$src" | tail -n +2 | awk '{print $1}')

    sign "$dest"
}

echo "note: bundling libmpv closure into $FRAMEWORKS"
bundle_dylib "$MPV_LIB"

# Point every Mach-O in MacOS/ (the thin launcher plus the .debug.dylib that actually links
# the libraries under Xcode's debug-dylib mode) at the bundled copies instead of the Homebrew
# keg. The app links libmpv and, for audio removal, the FFmpeg libraries directly; both are in
# the bundled closure, so rewrite every Homebrew reference, not just libmpv's.
MACOS_DIR="$BUILT_PRODUCTS_DIR/$EXECUTABLE_FOLDER_PATH"
for binary in "$MACOS_DIR"/*; do
    [ -f "$binary" ] || continue
    while IFS= read -r ref; do
        case "$ref" in
            "$BREW_PREFIX"/*)
                install_name_tool -change "$ref" "@rpath/$(basename "$ref")" "$binary" 2>/dev/null || true
                ;;
        esac
    done < <(otool -L "$binary" 2>/dev/null | tail -n +2 | awk '{print $1}')
done

echo "note: bundled $(ls "$FRAMEWORKS"/*.dylib 2>/dev/null | wc -l | tr -d ' ') dylib(s)"
