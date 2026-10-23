#!/bin/bash
# Compila Sonora y crea Sonora.app en la carpeta build/
set -e
cd "$(dirname "$0")"

swift build -c release

APP="build/Sonora.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Sonora "$APP/Contents/MacOS/Sonora"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Sonora</string>
    <key>CFBundleDisplayName</key><string>Sonora</string>
    <key>CFBundleIdentifier</key><string>com.sonora.player</string>
    <key>CFBundleExecutable</key><string>Sonora</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.music</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
EOF

codesign --force --deep -s - "$APP"
touch "$APP"   # refresca el ícono en Finder
echo "Listo: $(pwd)/$APP"
open build
