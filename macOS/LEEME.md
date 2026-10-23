# Sonora — reproductor minimalista para macOS

## Compilar
Requiere macOS 13+ y Xcode (o las Command Line Tools).

```
cd Sonora
chmod +x make-app.sh
./make-app.sh
```
Crea `build/Sonora.app`. Arrástrala a Aplicaciones.

También puedes abrir `Package.swift` en Xcode y presionar ▶︎.

## Instalador (DMG)
`./make-dmg.sh` crea `build/Sonora.dmg`: al abrirlo se ve Sonora y la carpeta Aplicaciones para arrastrar.

## OneDrive
En la biblioteca toca la **nube** → **Conectar OneDrive** → elige tu carpeta de música.
Las canciones suenan por streaming; con el botón **∫↓** de cada álbum se descargan al Mac para escuchar sin internet.
Requiere `Sources/Sonora/Secrets.swift` (copia `Secrets.swift.example` y pon tu Id. de cliente).

## Uso
- **Agregar música:** arrastra una carpeta (o archivos) sobre la ventana. También ⌘O.
- **Biblioteca:** clic en el símbolo ♪ abajo a la izquierda → álbumes → clic en un álbum → canciones.
- **Controles:** pasa el mouse sobre la carátula (anterior, play/pausa, siguiente, barra de avance).
- **Siempre encima:** botón de la esquina superior derecha.
- **Teclas:** ⌘P play/pausa, ⌘← / ⌘→ anterior/siguiente, ⌘L biblioteca. Funcionan las teclas multimedia del Mac.
- **Frecuencia nativa:** menú Reproducción → cambia el DAC a la frecuencia del archivo (44.1, 96, 192 kHz…).

## Formatos
FLAC, ALAC, WAV, AIFF, CAF, MP3, AAC/M4A. Lee etiquetas y carátulas (incluidas o `cover.jpg`/`folder.jpg`).

## Próximas mejoras posibles
- Modo exclusivo (hog mode) y bit-perfect completo
- Reproducción sin pausas (gapless)
- DSD (DSF/DFF), WavPack, APE, OGG
- Vista por artistas y listas
