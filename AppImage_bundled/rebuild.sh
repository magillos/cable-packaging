#!/bin/bash

set -eo pipefail

# ============================================================================
#  Cable AppImage Builder — bundles all dependencies
#
#  Builds on Debian 12 for glibc compatibility. Compiles C tools from source
#  and installs Python packages via venv into a self-contained AppDir.
#
#  Features:
#    - Caches downloaded sources in .build-cache/ for faster rebuilds
#    - Incremental mode: skips steps whose output already exists in AppDir
#    - Verifies critical binaries after build
#    - Builds Python with shared libraries and proper RPATH
#
#  Required build deps (run once on Debian 12):
#    sudo apt-get install -y build-essential autoconf automake libtool \
#      pkg-config git wget ca-certificates libjack-jackd2-dev libasound2-dev \
#      libexpat1-dev libsndfile1-dev flex bison python3-venv python3-dev \
#      libdbus-1-dev libdbus-glib-1-dev libglib2.0-dev zlib1g-dev libffi-dev \
#      libssl-dev libncurses5-dev libsqlite3-dev libreadline-dev \
#      liblzma-dev libbz2-dev libxcb-cursor0 libxcb-util1
# ============================================================================

# ---- version pins (edit here to upgrade) -----------------------------------
PYTHON_VERSION="3.11.12"
MXML_TAG="v2.12"
AJ_SNAPSHOT_TAG="release_0.9.9"
JACK_DELAY_TAG="v0.4.2"
GRAPHVIZ_TAG="14.1.2"

# ---- paths -----------------------------------------------------------------
SRC_DIR="$(pwd)"
BUILD_DIR="/tmp/cable-appimage-build"
PREFIX="${BUILD_DIR}/AppDir/usr"
CACHE_DIR="${SRC_DIR}/.build-cache"

export PKG_CONFIG_PATH="${PREFIX}/lib/pkgconfig:${PKG_CONFIG_PATH}"

echo "============================================"
echo "  Cable AppImage — Dependency Build"
echo "============================================"

# ---- locate appimagetool ---------------------------------------------------
if command -v appimagetool >/dev/null 2>&1; then
    APPIMAGETOOL="appimagetool"
elif [ -f "${SRC_DIR}/appimagetool.AppImage" ]; then
    APPIMAGETOOL="${SRC_DIR}/appimagetool.AppImage"
else
    echo ""
    echo "  ERROR: appimagetool not found."
    echo "  Either install it system-wide or place appimagetool.AppImage in:"
    echo "    ${SRC_DIR}"
    exit 1
fi
echo "  Using appimagetool: ${APPIMAGETOOL}"

# ---- build mode selection --------------------------------------------------
echo ""
BUILD_MODE="full"
if [ -d "${BUILD_DIR}/AppDir" ]; then
    if [ -t 0 ]; then
        echo "  An existing AppDir was found at ${BUILD_DIR}/AppDir"
        echo ""
        echo "  [f] Full rebuild   — wipe AppDir and rebuild everything from scratch"
        echo "  [i] Incremental    — skip steps whose output already exists in AppDir"
        echo ""
        read -rp "  Build mode [f/i, default: i]: " MODE_ANS
        case "${MODE_ANS}" in
            f|F) BUILD_MODE="full" ;;
            *)   BUILD_MODE="incremental" ;;
        esac
    else
        # Non-interactive (CI): default to full to avoid stale state surprises
        BUILD_MODE="full"
        echo "  Non-interactive session detected — defaulting to full rebuild."
    fi
else
    echo "  No existing AppDir found — performing full build."
fi
echo "  Mode: ${BUILD_MODE}"

# ---- helper: run configure verbosely but only show last lines on success ---
# On failure, the full output has already scrolled by via tee; exit triggers.
run_configure() {
    ./configure "$@"
}

# ---- helper: clone or update from cache ------------------------------------
# Keeps a regular shallow clone in .build-cache/git/<name>/ and cp -r's it to
# dest for each build, so the cached copy stays clean and unbuilt.
clone_cached() {
    local repo="$1" tag="$2" dest="$3"
    local cache_name
    cache_name="$(basename "${repo}" .git)"
    local cached_clone="${CACHE_DIR}/git/${cache_name}"

    mkdir -p "${CACHE_DIR}/git"

    if [ -d "${cached_clone}" ]; then
        echo "  Using cached clone of ${cache_name}..."
    else
        echo "  Cloning ${cache_name} (tag ${tag}) into cache..."
        git clone --depth 1 --branch "${tag}" "${repo}" "${cached_clone}" \
            2>&1 | tail -1
    fi

    echo "  Copying ${cache_name} to build dir..."
    rsync -a --exclude=.git "${cached_clone}/" "${dest}/"
}

# ---- helper: download tarball to cache -------------------------------------
# After calling this, the tarball lives at: ${CACHE_DIR}/tarballs/<filename>
fetch_cached() {
    local url="$1" filename="$2"
    local cached="${CACHE_DIR}/tarballs/${filename}"
    mkdir -p "${CACHE_DIR}/tarballs"
    if [ -f "${cached}" ]; then
        echo "  Using cached ${filename}"
    else
        echo "  Downloading ${filename}..."
        wget -q --show-progress -O "${cached}" "${url}"
    fi
}

# ---- helper: incremental step guard ----------------------------------------
# Usage: should_build <marker_binary>
# Returns 0 (run the step) or 1 (skip it).
should_build() {
    local marker="$1"
    if [ "${BUILD_MODE}" = "incremental" ] && [ -e "${marker}" ]; then
        echo "  Skipping — found: ${marker}"
        return 1
    fi
    return 0
}

# ---- check build deps ------------------------------------------------------
echo ""
echo "[0/10] Checking build dependencies..."
MISSING_PKG=""
for pkg in build-essential autoconf automake libtool pkg-config git \
           ca-certificates libjack-jackd2-dev libasound2-dev libexpat1-dev \
           libsndfile1-dev flex bison python3-venv python3-dev \
           libdbus-1-dev libdbus-glib-1-dev libglib2.0-dev zlib1g-dev \
           libffi-dev libssl-dev libncurses5-dev libsqlite3-dev \
           libxcb-cursor0 libxcb-util1; do
    if ! dpkg -s "$pkg" >/dev/null 2>&1; then
        MISSING_PKG="${MISSING_PKG} ${pkg}"
    fi
done
if [ -n "${MISSING_PKG}" ]; then
    echo ""
    echo "  Missing build dependencies:"
    for p in ${MISSING_PKG}; do echo "    - ${p}"; done
    echo ""
    echo "  Install with:"
    echo "    sudo apt-get install -y${MISSING_PKG}"
    echo ""
    if [ -t 0 ] && { [ -x "$(command -v sudo 2>/dev/null)" ] || [ "$(id -u)" = "0" ]; }; then
        read -rp "  Attempt to install now? [y/N] " ANS
        if [ "$ANS" = "y" ] || [ "$ANS" = "Y" ]; then
            if [ "$(id -u)" != "0" ]; then
                if sudo -v >/dev/null 2>&1; then
                    sudo apt-get update -qq
                    sudo apt-get install -y -qq ${MISSING_PKG}
                else
                    echo "  sudo failed — run as root or install manually, then re-run."
                    exit 1
                fi
            else
                apt-get update -qq
                apt-get install -y -qq ${MISSING_PKG}
            fi
        else
            echo "  Aborting — install dependencies first and re-run."
            exit 1
        fi
    else
        echo "  Install the packages above as root, then re-run."
        exit 1
    fi
fi

# ---- set up build directory ------------------------------------------------
echo ""
echo "[1/10] Setting up build directory..."
if [ "${BUILD_MODE}" = "full" ]; then
    echo "  Wiping ${BUILD_DIR}..."
    rm -rf "${BUILD_DIR}"
fi
mkdir -p "${BUILD_DIR}/sources"
mkdir -p "${PREFIX}/bin" "${PREFIX}/lib" "${PREFIX}/include"
mkdir -p "${PREFIX}/share/applications"
mkdir -p "${PREFIX}/share/icons/hicolor/scalable/apps"

# ---- build Python from source ----------------------------------------------
echo ""
echo "[2/10] Building Python ${PYTHON_VERSION} from source..."
if should_build "${PREFIX}/bin/python3"; then
    PYTHON_TAR="Python-${PYTHON_VERSION}.tar.xz"
    PYTHON_URL="https://www.python.org/ftp/python/${PYTHON_VERSION}/${PYTHON_TAR}"
    fetch_cached "${PYTHON_URL}" "${PYTHON_TAR}"

    echo "  Extracting..."
    cd "${BUILD_DIR}/sources"
    tar -xf "${CACHE_DIR}/tarballs/${PYTHON_TAR}"
    cd "Python-${PYTHON_VERSION}"

    run_configure \
        --prefix="${PREFIX}" \
        --with-ensurepip=install \
        --disable-test-modules
    make -j"$(nproc)"
    make install
else
    echo "  Python already built."
fi

export PATH="${PREFIX}/bin:${PATH}"
PYTHON_EXE="${PREFIX}/bin/python3"

# ---- build mxml (dependency of aj-snapshot) --------------------------------
echo ""
echo "[3/10] Building mxml..."
if should_build "${PREFIX}/lib/libmxml.a"; then
    cd "${BUILD_DIR}/sources"
    clone_cached "https://github.com/michaelrsweet/mxml.git" "${MXML_TAG}" mxml
    cd mxml
    run_configure --prefix="${PREFIX}" --disable-shared
    make -j"$(nproc)"
    make install
else
    echo "  mxml already built."
fi

# ---- build aj-snapshot -----------------------------------------------------
echo ""
echo "[4/10] Building aj-snapshot..."
if should_build "${PREFIX}/bin/aj-snapshot"; then
    cd "${BUILD_DIR}/sources"
    clone_cached "https://git.code.sf.net/p/aj-snapshot/code" "${AJ_SNAPSHOT_TAG}" aj-snapshot
    cd aj-snapshot
    ./autogen.sh 2>&1 | tail -3
    CFLAGS="-I${PREFIX}/include" \
    LDFLAGS="-L${PREFIX}/lib" \
        run_configure --prefix="${PREFIX}"
    make -j"$(nproc)"
    make install
else
    echo "  aj-snapshot already built."
fi

# ---- build jack_delay ------------------------------------------------------
echo ""
echo "[5/10] Building jack_delay..."
if should_build "${PREFIX}/bin/jack_delay"; then
    cd "${BUILD_DIR}/sources"
    clone_cached "https://github.com/ericfont/jack_delay.git" "${JACK_DELAY_TAG}" jack_delay
    cd jack_delay
    make -C source -j"$(nproc)"
    install -Dm755 source/jack_delay "${PREFIX}/bin/"
else
    echo "  jack_delay already built."
fi

# ---- build graphviz --------------------------------------------------------
echo ""
echo "[6/10] Building graphviz..."
if should_build "${PREFIX}/bin/dot"; then
    cd "${BUILD_DIR}/sources"
    clone_cached "https://gitlab.com/graphviz/graphviz.git" "${GRAPHVIZ_TAG}" graphviz
    cd graphviz
    ./autogen.sh 2>&1 | tail -3
    run_configure \
        --prefix="${PREFIX}" \
        --disable-static \
        --enable-shared \
        --without-x \
        --without-gdk-pixbuf \
        --without-gtk \
        --without-qt \
        --without-poppler \
        --without-ghostscript \
        --without-libgd \
        --without-lasi \
        --without-devil \
        --without-doxygen \
        --without-graphite2 \
        --without-pangocairo
    make -j"$(nproc)"
    make install
else
    echo "  graphviz already built."
fi

# ---- install Python packages via venv --------------------------------------
echo ""
echo "[7/10] Installing Python packages (venv)..."
SITE_DEST="$("${PYTHON_EXE}" -c 'import sysconfig; print(sysconfig.get_path("purelib"))')"
if should_build "${SITE_DEST}"; then
    cd "${BUILD_DIR}"
    "${PYTHON_EXE}" -m venv venv
    source venv/bin/activate
    pip install --upgrade pip wheel setuptools -q
    echo "  Installing jack-client requests pyalsaaudio dbus-python graphviz PyQt6 packaging..."
    pip install \
        jack-client \
        requests \
        pyalsaaudio \
        dbus-python \
        graphviz \
        PyQt6 \
        packaging \
        -q
    SITE_SRC=$(python3 -c 'import sysconfig; print(sysconfig.get_path("purelib"))')
    deactivate

    echo "  Copying site-packages from ${SITE_SRC}..."
    mkdir -p "${SITE_DEST}"
    cp -r "${SITE_SRC}/." "${SITE_DEST}/"
else
    echo "  Python packages already installed."
fi

# ---- copy application files ------------------------------------------------
echo ""
echo "[8/10] Copying application files..."
cp -r "${SRC_DIR}/Cable.py" \
      "${SRC_DIR}/cable_core" \
      "${SRC_DIR}/cables" \
      "${SRC_DIR}/graph" \
      "${SRC_DIR}/connection-manager.py" \
      "${PREFIX}/bin/"

cp "${SRC_DIR}/com.github.magillos.cable.desktop" \
   "${PREFIX}/share/applications/"

for icon in jack-plug.svg jack-plug-light.svg jack-plug-dark.svg; do
    cp "${SRC_DIR}/${icon}" "${PREFIX}/share/icons/hicolor/scalable/apps/"
    cp "${SRC_DIR}/${icon}" "${PREFIX}/bin/"
done

# ---- bundle Qt XCB platform plugin dependencies ----------------------------
# WARNING: never copy libc.so.6, libxcb.so.1, libfontconfig, or libfreetype
# from the build machine; doing so causes ABI crashes on distros with newer
# glibc / fontconfig.
echo ""
echo "[8.5/10] Bundling Qt XCB platform plugin dependencies..."
for libpath in \
    /usr/lib/x86_64-linux-gnu/libxcb-cursor.so.0 \
    /usr/lib/x86_64-linux-gnu/libxcb-util.so.1; do
    if [ -f "$libpath" ]; then
        cp -L "$libpath" "${PREFIX}/lib/"
    fi
done

# Root-level symlinks needed by appimagetool
cd "${BUILD_DIR}/AppDir"
ln -sf usr/share/applications/com.github.magillos.cable.desktop cable.desktop
ln -sf usr/share/icons/hicolor/scalable/apps/jack-plug.svg jack-plug.svg
ln -sf usr/share/icons/hicolor/scalable/apps/jack-plug-light.svg jack-plug-light.svg
ln -sf usr/share/icons/hicolor/scalable/apps/jack-plug-dark.svg jack-plug-dark.svg
ln -sf AppRun cable
ln -sf AppRun connection-manager
cd "${SRC_DIR}"

# ---- create AppRun ---------------------------------------------------------
echo ""
echo "[9/10] Creating AppRun..."
cat > "${BUILD_DIR}/AppDir/AppRun" << 'APPRUNEOF'
#!/bin/bash
set -e

HERE="$(dirname "$(readlink -f "${0}")")"

# --- bundled binaries & shared libraries ---
export PATH="${HERE}/usr/bin:${PATH}"
export LD_LIBRARY_PATH="${HERE}/usr/lib:${HERE}/usr/lib/graphviz:${LD_LIBRARY_PATH}"

# --- Python environment ---
export PYTHONHOME="${HERE}/usr"
SPD="${HERE}/usr/lib/python3/site-packages"
if [ -d "$SPD" ]; then
    export PYTHONPATH="${SPD}:${HERE}/usr/bin:${PYTHONPATH}"
    # Qt plugins live inside the PyQt6 wheel
    export QT_PLUGIN_PATH="${SPD}/PyQt6/Qt6/plugins:${QT_PLUGIN_PATH}"
fi

# --- Graphviz ---
export GRAPHVIZ_DOT="${HERE}/usr/bin/dot"

# --- XDG / desktop integration ---
export XDG_DATA_DIRS="${HERE}/usr/share:${XDG_DATA_DIRS}"

# --- Multi-call: connection-manager vs Cable ---
if [[ "$*" == *"connection-manager"* ]]; then
    ARGS=()
    for arg in "$@"; do
        [ "$arg" = "connection-manager" ] && continue
        ARGS+=("$arg")
    done
    exec python3 "${HERE}/usr/bin/connection-manager.py" "${ARGS[@]}"
else
    exec python3 "${HERE}/usr/bin/Cable.py" "$@"
fi
APPRUNEOF

chmod +x "${BUILD_DIR}/AppDir/AppRun"


# ---- verify runtime linkage -------------------------------------------------
echo ""
echo "[9.5/10] Verifying runtime dependencies..."
for bin in "${PREFIX}/bin/python3" "${PREFIX}/bin/dot"; do
    [ -x "$bin" ] || continue
    echo "  Checking $(basename "$bin")"
    ldd "$bin" || exit 1
done

# ---- strip binaries ---------------------------------------------------------
echo ""
echo "[9.6/10] Stripping binaries..."
find "${PREFIX}" -type f \( -perm -111 -o -name "*.so*" \) \
    -exec strip --strip-unneeded {} + 2>/dev/null || true

# ---- build the AppImage ----------------------------------------------------
echo ""
echo "[10/10] Building AppImage..."

for mnt in /tmp/.mount_Cable-*; do
    if [ -d "$mnt" ]; then
        echo "  Unmounting stale AppImage mount: $mnt"
        fusermount -u "$mnt" 2>/dev/null || umount "$mnt" 2>/dev/null || true
    fi
done

if [ -f "Cable-x86_64.AppImage" ]; then
    mv -f Cable-x86_64.AppImage "Cable-x86_64.AppImage.old" 2>/dev/null || true
fi

ARCH=x86_64 "${APPIMAGETOOL}" "${BUILD_DIR}/AppDir"

cp Cable-x86_64.AppImage "${SRC_DIR}/"

if [ "${BUILD_MODE}" = "full" ]; then
    rm -rf "${BUILD_DIR}"
else
    echo "  AppDir preserved at ${BUILD_DIR}/AppDir (incremental mode)."
fi

echo ""
echo "============================================"
echo "  Done!"
ls -lh "${SRC_DIR}/Cable-x86_64.AppImage"
echo "============================================"
