# Sonora para Android

## Instalar el APK (sin Android Studio)
1. Pasa `Sonora.apk` al teléfono (cable, Google Drive, correo, WhatsApp…) y ábrelo.
2. Si Android lo pide, permite **Instalar apps desconocidas** para la app con que lo abriste.
3. En Samsung: si aparece **Bloqueador automático**, desactívalo temporalmente en
   Ajustes → Seguridad y privacidad → Bloqueador automático.
4. Si Play Protect avisa "app desconocida", elige **Instalar de todas formas**.

## Compilar
1. Copia `local.properties.example` a `local.properties` y completa `sdk.dir` y `onedrive.clientId`.
2. `./gradlew assembleRelease` (o ábrelo en Android Studio).

El APK queda en `app/build/outputs/apk/release/`.

## OneDrive
Usa el mismo registro de Microsoft Entra que la versión iPhone (URI de redirección `sonora://auth`).
