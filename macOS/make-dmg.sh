#!/bin/bash
# Crea build/Sonora.dmg: ventana con Sonora.app, una flecha y la carpeta Aplicaciones para arrastrar.
set -e
cd "$(dirname "$0")"

APP="build/Sonora.app"
VOL="Sonora"
DMG="build/Sonora.dmg"
TMP="build/Sonora-tmp.dmg"
STAGE="build/dmg"

[ -d "$APP" ] || ./make-app.sh

echo "Preparando contenido…"
rm -rf "$STAGE" "$DMG" "$TMP"
mkdir -p "$STAGE/.background"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Aplicaciones"

# Fondo nítido en pantallas Retina (1x + 2x en un solo archivo)
if command -v tiffutil >/dev/null; then
    tiffutil -cathidpicheck Resources/dmg-background.png Resources/dmg-background@2x.png \
        -out "$STAGE/.background/background.tiff" >/dev/null 2>&1
    BG="background.tiff"
else
    cp Resources/dmg-background.png "$STAGE/.background/background.png"
    BG="background.png"
fi

# Si quedó montado un Sonora anterior, desmontarlo
hdiutil detach "/Volumes/$VOL" -quiet 2>/dev/null || true

echo "Creando imagen de disco…"
hdiutil create -srcfolder "$STAGE" -volname "$VOL" -fs HFS+ -format UDRW -ov "$TMP" >/dev/null
DEV=$(hdiutil attach -readwrite -noverify -noautoopen "$TMP" | grep -E '^/dev/' | head -1 | awk '{print $1}')
sleep 2

# Ícono del disco
cp Resources/AppIcon.icns "/Volumes/$VOL/.VolumeIcon.icns"
SetFile -a C "/Volumes/$VOL" 2>/dev/null || xcrun SetFile -a C "/Volumes/$VOL" 2>/dev/null || true

echo "Ordenando la ventana (si macOS pide permiso para controlar Finder, acepta)…"
osascript <<EOF
tell application "Finder"
    tell disk "$VOL"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set the bounds of container window to {200, 120, 860, 548}
        set opts to the icon view options of container window
        set arrangement of opts to not arranged
        set icon size of opts to 128
        set text size of opts to 13
        set background picture of opts to file ".background:$BG"
        set position of item "Sonora.app" of container window to {170, 190}
        set position of item "Aplicaciones" of container window to {490, 190}
        close
        open
        update without registering applications
        delay 2
        close
    end tell
end tell
EOF

sync
hdiutil detach "$DEV" -quiet || hdiutil detach "$DEV" -force -quiet
echo "Comprimiendo…"
hdiutil convert "$TMP" -format UDZO -imagekey zlib-level=9 -o "$DMG" >/dev/null
rm -f "$TMP"
rm -rf "$STAGE"

echo "Listo: $(pwd)/$DMG"
open -R "$DMG"
