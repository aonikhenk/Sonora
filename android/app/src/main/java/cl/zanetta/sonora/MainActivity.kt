package cl.zanetta.sonora

import android.app.Application
import android.content.ComponentName
import android.content.Intent
import android.net.Uri
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.browser.customtabs.CustomTabsIntent
import androidx.compose.runtime.mutableStateOf
import androidx.lifecycle.lifecycleScope
import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.common.MediaMetadata
import androidx.media3.common.MimeTypes
import androidx.media3.common.Player
import androidx.media3.session.MediaController
import androidx.media3.session.SessionToken
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.guava.await
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

class SonoraApp : Application() {
    override fun onCreate() {
        super.onCreate()
        // Guarda cualquier cierre inesperado para mostrarlo al volver a abrir la app
        val previous = Thread.getDefaultUncaughtExceptionHandler()
        Thread.setDefaultUncaughtExceptionHandler { thread, e ->
            runCatching {
                java.io.File(filesDir, "crash.txt").writeText(
                    "Sonora ${BuildConfig.VERSION_NAME} · Android ${android.os.Build.VERSION.RELEASE} · ${android.os.Build.MODEL}\n" +
                        "Hilo: ${thread.name}\n\n" + android.util.Log.getStackTraceString(e)
                )
            }
            previous?.uncaughtException(thread, e)
        }
        OneDrive.init(this)
        Lyrics.init(cacheDir)
        Library.init(this)
    }
}

fun isTelevision(context: android.content.Context): Boolean {
    val ui = context.getSystemService(android.content.Context.UI_MODE_SERVICE) as android.app.UiModeManager
    return ui.currentModeType == android.content.res.Configuration.UI_MODE_TYPE_TELEVISION ||
        context.packageManager.hasSystemFeature(android.content.pm.PackageManager.FEATURE_LEANBACK)
}

class MainActivity : ComponentActivity() {
    private val hub = PlayerHub()
    val nowPlaying get() = hub.nowPlaying
    val pickOneDriveFolder = mutableStateOf(false)
    val crashReport = mutableStateOf<String?>(null)

    /** Abre el menú de compartir de Android (WhatsApp, correo…) con el informe de error. */
    fun shareCrash(text: String) {
        val send = Intent(Intent.ACTION_SEND).setType("text/plain")
            .putExtra(Intent.EXTRA_SUBJECT, "Error de Sonora")
            .putExtra(Intent.EXTRA_TEXT, text)
        startActivity(Intent.createChooser(send, "Compartir error"))
    }

    fun copyCrash(text: String) {
        val cm = getSystemService(CLIPBOARD_SERVICE) as android.content.ClipboardManager
        cm.setPrimaryClip(android.content.ClipData.newPlainText("Error de Sonora", text))
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // En un televisor, siempre la versión de TV (horizontal, pantalla completa, inicio de sesión con código)
        if (isTelevision(this)) {
            startActivity(Intent(this, TvActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK))
            finish()
            return
        }
        enableEdgeToEdge()
        java.io.File(filesDir, "crash.txt").takeIf { it.exists() }?.let {
            crashReport.value = it.readText()
            it.delete()
        }
        setContent { SonoraUi(this) }
        handleAuth(intent)

        hub.connect(this, lifecycleScope)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        handleAuth(intent)
    }

    override fun onDestroy() {
        hub.release()
        super.onDestroy()
    }

    // MARK: OneDrive

    fun connectOneDrive() {
        if (!OneDrive.isConfigured) {
            Library.error.value = "Falta el Id. de cliente de OneDrive (local.properties)."
            return
        }
        CustomTabsIntent.Builder().build().launchUrl(this, OneDrive.authorizeUri())
    }

    private fun handleAuth(intent: Intent?) {
        val uri: Uri = intent?.data ?: return
        if (uri.scheme != "sonora" || uri.host != "auth") return
        setIntent(Intent(this, MainActivity::class.java))
        lifecycleScope.launch {
            try {
                withContext(Dispatchers.IO) { OneDrive.handleRedirect(uri) }
                pickOneDriveFolder.value = true
            } catch (e: Exception) {
                Library.error.value = e.message
            }
        }
    }

    // MARK: Reproducción

    fun play(album: Album, index: Int) = hub.play(album, index)
    fun togglePlay() = hub.togglePlay()
    fun next() = hub.next()
    fun previous() = hub.previous()
    fun seek(ms: Long) = hub.seek(ms)
}
