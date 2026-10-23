#!/bin/bash
# Crea build/Sonora.dmg: ventana con Sonora.app, una flecha y la carpeta Aplicaciones para arrastrar.
# Usa dmgbuild (no necesita permiso para controlar Finder).
set -e
cd "$(dirname "$0")"

APP="build/Sonora.app"
DMG="build/Sonora.dmg"
[ -d "$APP" ] || ./make-app.sh

# Desmontar un "Sonora" que haya quedado abierto de intentos anteriores
hdiutil detach "/Volumes/Sonora" -force -quiet 2>/dev/null || true
rm -f "$DMG" build/Sonora-tmp.dmg
rm -rf build/dmg

# dmgbuild en un entorno propio (solo la primera vez descarga ~1 MB)
VENV="build/.dmgbuild"
if [ ! -x "$VENV/bin/dmgbuild" ]; then
    echo "Instalando dmgbuild…"
    python3 -m venv "$VENV"
    "$VENV/bin/pip" install --quiet --upgrade pip
    "$VENV/bin/pip" install --quiet dmgbuild
fi

cat > build/dmg-settings.py <<'EOF'
import os.path
application = defines.get("app", "build/Sonora.app")
appname = os.path.basename(application)

format = "UDZO"
filesystem = "HFS+"
files = [application]
symlinks = {"Aplicaciones": "/Applications"}
icon = "Resources/AppIcon.icns"

background = "Resources/dmg-background.png"   # usa también dmg-background@2x.png en pantallas Retina
window_rect = ((200, 120), (660, 400))
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
icon_size = 128
text_size = 13
icon_locations = {
    appname: (170, 190),
    "Aplicaciones": (490, 190),
}
EOF

echo "Creando Sonora.dmg…"
"$VENV/bin/dmgbuild" -s build/dmg-settings.py -D app="$APP" "Sonora" "$DMG"

echo "Listo: $(pwd)/$DMG"
open -R "$DMG"
