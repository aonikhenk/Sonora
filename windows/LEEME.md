# Sonora para Windows 11

## Instalar
Ejecuta `Sonora-Setup-x.y.z.exe`. Se instala solo para tu usuario (no pide permisos de administrador)
y crea accesos en el menú Inicio y el escritorio.

Como el instalador no está firmado, Windows SmartScreen puede avisar: **Más información → Ejecutar de todas formas**.

## Uso
- **Agregar música:** arrastra carpetas sobre la ventana, o ♪ → **+**.
- **OneDrive:** ♪ → **nube** → Conectar OneDrive → elige tu carpeta de música.
  Suena por streaming; el botón **∫↓** de cada álbum lo descarga al PC para escuchar sin internet.
- **Teclas:** Espacio reproducir/pausa · Ctrl+← / Ctrl+→ anterior/siguiente · Ctrl+L biblioteca · Ctrl+O agregar carpeta.
  Funcionan las teclas multimedia del teclado y los controles de Windows.

## Compilar (Linux o Windows)
1. `npm install`
2. Copia `secrets.example.json` a `secrets.json` con tu Id. de cliente de Microsoft Entra.
3. `npm run dist` → `dist/Sonora-Setup-x.y.z.exe` (requiere `makensis`).
