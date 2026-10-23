## Primero
Copia `Secrets.swift.example` a `Sonora/Secrets.swift` y pon tu Id. de cliente de Microsoft Entra (ver README principal).

# Sonora para iPhone

## Instalar en tu iPhone (Apple ID gratuito)
1. Abre `Sonora.xcodeproj` con Xcode 16 o superior.
2. Xcode → Ajustes → Cuentas → agrega tu Apple ID.
3. Clic en el proyecto "Sonora" (barra izquierda) → pestaña **Signing & Capabilities** → en **Team** elige tu nombre (Personal Team).
   - Si dice que el Bundle Identifier no está disponible, cámbialo (por ejemplo `cl.zanetta.sonora2`).
4. Conecta el iPhone por cable, elígelo arriba en Xcode y presiona ▶︎.
5. La primera vez, en el iPhone: Ajustes → General → VPN y gestión de dispositivos → confía en tu Apple ID.
   También activa Ajustes → Privacidad y seguridad → **Modo desarrollador** si lo pide.

Con Apple ID gratuito la app deja de abrir a los 7 días: conecta el iPhone y presiona ▶︎ otra vez (la música no se borra).

## Agregar música
- **OneDrive (streaming):** ♪ → **Conectar OneDrive** → inicia sesión → elige tu carpeta de música → **Usar como biblioteca**.
  Las canciones suenan por streaming y quedan guardadas en un caché (máx. 3 GB, se limpia solo).
  Estructura ideal: `Artista/Álbum/01 - Canción.flac`. Calidad y carátula se completan al escuchar.
- **iCloud Drive:** ♪ → **+** → **Vincular carpeta (iCloud Drive)**.
- **Copiar al iPhone:** ♪ → **+** → **Copiar al iPhone** (para escuchar sin internet).

## Uso
- Sin música sonando se ve el logo. Toca ♪ → álbum → canción.
- Reproduciendo: carátula grande, nombre, barra de avance y ⏮ ⏯ ⏭.
- Funciona con pantalla bloqueada y en el Centro de control.
- Para borrar un álbum del iPhone: entra al álbum → ⋯ → Eliminar del iPhone.

## Formatos
FLAC, ALAC, WAV, AIFF, MP3, AAC. La app pide al iPhone/DAC la frecuencia nativa del archivo.
