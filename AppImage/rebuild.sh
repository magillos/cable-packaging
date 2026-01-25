#!/bin/bash



set -e

echo "Building Cable AppImage..."

echo "Creating directory structure..."
mkdir -p AppDir/usr/bin AppDir/usr/lib AppDir/usr/share/icons/hicolor/scalable/apps AppDir/usr/share/applications

echo "Copying application files..."
cp -r Cable.py cable_core cables graph connection-manager.py AppDir/usr/bin/


echo "Copying desktop file and icon..."
cp com.github.magillos.cable.desktop AppDir/usr/share/applications/
cp jack-plug.svg AppDir/usr/share/icons/hicolor/scalable/apps/


echo "Creating symlinks..."
cd AppDir
ln -sf usr/share/applications/com.github.magillos.cable.desktop cable.desktop
ln -sf usr/share/icons/hicolor/scalable/apps/jack-plug.svg jack-plug.svg
ln -sf AppRun cable
ln -sf AppRun connection-manager
cd ..


echo "Copying icon to application directory..."
cp jack-plug.svg AppDir/usr/bin/


echo "Creating AppRun script..."
cat > AppDir/AppRun << 'EOF'
#!/bin/bash

# Exit on any error
set -e

# Get the absolute path of the AppRun script
HERE="$(dirname "$(readlink -f "${0}")")"

# Set up Python path to include our application modules
export PYTHONPATH="${HERE}/usr/bin:${PYTHONPATH}"

# Set up Qt to find icons within the AppImage
export QT_PLUGIN_PATH="${HERE}/usr/lib/qt/plugins:${QT_PLUGIN_PATH}"
export QML2_IMPORT_PATH="${HERE}/usr/lib/qt/qml:${QML2_IMPORT_PATH}"
export XDG_DATA_DIRS="${HERE}/usr/share:${XDG_DATA_DIRS}"

# Check if we were invoked as "connection-manager"
if [[ "$*" == *"connection-manager"* ]]; then
    # Remove "connection-manager" from arguments and run connection-manager.py
    ARGS=()
    SKIP_NEXT=false
    for arg in "$@"; do
        if [ "$arg" = "connection-manager" ]; then
            continue
        fi
        ARGS+=("$arg")
    done
    exec python3 "${HERE}/usr/bin/connection-manager.py" "${ARGS[@]}"
else
    # Run the main Cable application
    exec python3 "${HERE}/usr/bin/Cable.py" "$@"
fi
EOF


echo "Making AppRun executable..."
chmod +x AppDir/AppRun


echo "Creating AppImage..."
ARCH=x86_64 appimagetool AppDir

echo "AppImage created successfully!"
ls -lh Cable-x86_64.AppImage
