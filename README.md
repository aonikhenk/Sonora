<p align="center"><img src="macOS/Resources/icon_1024.png" width="160" alt="Sonora"></p>

# Sonora

Minimalist hi-res music player for macOS and iPhone — FLAC, ALAC, WAV, AIFF, with OneDrive streaming and iCloud Drive libraries.

Reproductor de música minimalista para macOS e iPhone: FLAC, ALAC, WAV y AIFF en alta resolución, con streaming desde OneDrive e iCloud Drive.

## Características

| | macOS | iPhone |
|---|---|---|
| FLAC, ALAC, WAV, AIFF, MP3, AAC | ✓ | ✓ |
| Etiquetas y carátulas (incluidas o `cover.jpg`) | ✓ | ✓ |
| Biblioteca por álbumes → canciones | ✓ | ✓ |
| Frecuencia nativa del DAC (44.1 / 96 / 192 kHz…) | ✓ | ✓ (DAC USB-C) |
| Agregar música | arrastrar carpeta | OneDrive, iCloud Drive, copiar al iPhone |
| Streaming desde OneDrive con caché | — | ✓ |
| Teclas multimedia / pantalla bloqueada | ✓ | ✓ |

## macOS

Requiere macOS 13+ y Xcode o las Command Line Tools.

```bash
cd macOS
./make-app.sh
```

Crea `macOS/build/Sonora.app`. Arrastra una carpeta de música sobre la ventana y toca ♪ para ver la biblioteca.

## iPhone

Requiere Xcode 16+ e iOS 17+.

1. Copia `iOS/Secrets.swift.example` a `iOS/Sonora/Secrets.swift`.
2. Para usar OneDrive, registra tu propia app en [Microsoft Entra](https://entra.microsoft.com) → Registros de aplicaciones:
   - Tipos de cuenta: *Cualquier inquilino de Entra ID + cuentas personales de Microsoft*
   - URI de redirección: *Cliente público/nativo* → `sonora://auth`
   - Permisos de API (Microsoft Graph, delegados): `Files.Read`, `offline_access`, `User.Read`
   - Copia el *Id. de aplicación (cliente)* en `Secrets.swift`.
3. Abre `iOS/Sonora.xcodeproj`, elige tu Team en *Signing & Capabilities*, cambia el Bundle Identifier si hace falta y presiona ▶︎.

Más detalles en [iOS/LEEME.md](iOS/LEEME.md).

## Licencia

MIT
