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
        OneDrive.init(this)
        Library.init(this)
    }
}

data class NowPlaying(
    val track: Track? = null,
    val isPlaying: Boolean = false,
    val buffering: Boolean = false,
    val positionMs: Long = 0,
    val durationMs: Long = 0,
    val quality: String = "",
)

class MainActivity : ComponentActivity() {
    private var controller: MediaController? = null
    val nowPlaying = mutableStateOf(NowPlaying())
    val pickOneDriveFolder = mutableStateOf(false)

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        setContent { SonoraUi(this) }
        handleAuth(intent)

        lifecycleScope.launch {
            val token = SessionToken(this@MainActivity, ComponentName(this@MainActivity, PlaybackService::class.java))
            val c = MediaController.Builder(this@MainActivity, token).buildAsync().await()
            controller = c
            c.addListener(object : Player.Listener {
                override fun onEvents(player: Player, events: Player.Events) = refresh()
            })
            refresh()
            while (true) {
                delay(500)
                if (c.isPlaying) refresh()
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        handleAuth(intent)
    }

    override fun onDestroy() {
        controller?.release()
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

    fun play(album: Album, index: Int) {
        val c = controller ?: return
        val items = album.tracks.map { t ->
            val art = Library.artFile(t.albumKey).takeIf { it.exists() }?.let { Uri.fromFile(it) }
            MediaItem.Builder()
                .setMediaId(t.uri)
                .setMediaMetadata(
                    MediaMetadata.Builder()
                        .setTitle(t.title).setArtist(t.artist).setAlbumTitle(t.album)
                        .setTrackNumber(t.trackNumber).setArtworkUri(art)
                        .build()
                )
                .build()
        }
        c.setMediaItems(items, index, 0)
        c.prepare()
        c.play()
    }

    fun togglePlay() = controller?.let { if (it.isPlaying) it.pause() else { if (it.playbackState == Player.STATE_IDLE) it.prepare(); it.play() } }
    fun next() = controller?.seekToNextMediaItem()
    fun previous() = controller?.let { if (it.currentPosition > 3000) it.seekTo(0) else it.seekToPreviousMediaItem() }
    fun seek(ms: Long) = controller?.seekTo(ms)

    private fun refresh() {
        val c = controller ?: return
        val id = c.currentMediaItem?.mediaId
        val track = id?.let { uri -> Library.albums.value.asSequence().flatMap { it.tracks }.firstOrNull { it.uri == uri } }
            ?: c.currentMediaItem?.mediaMetadata?.let { m ->
                Track(id ?: "", id ?: "", m.title?.toString() ?: "", m.artist?.toString() ?: "", m.albumTitle?.toString() ?: "",
                    "", 0, 1, null, 0, "", "")
            }
        nowPlaying.value = NowPlaying(
            track = if (c.mediaItemCount == 0 || c.playbackState == Player.STATE_ENDED) null else track,
            isPlaying = c.playWhenReady,
            buffering = c.playbackState == Player.STATE_BUFFERING,
            positionMs = c.currentPosition,
            durationMs = c.duration.takeIf { it != C.TIME_UNSET } ?: (track?.durationMs ?: 0),
            quality = quality(c, track),
        )
    }

    private fun quality(c: Player, t: Track?): String {
        val f = c.currentTracks.groups.firstOrNull { it.type == C.TRACK_TYPE_AUDIO }?.getTrackFormat(0)
        val name = when (f?.sampleMimeType) {
            MimeTypes.AUDIO_FLAC -> "FLAC"
            MimeTypes.AUDIO_ALAC -> "ALAC"
            MimeTypes.AUDIO_RAW -> "WAV"
            MimeTypes.AUDIO_MPEG -> "MP3"
            MimeTypes.AUDIO_AAC -> "AAC"
            else -> t?.format?.uppercase() ?: ""
        }
        val rate = f?.sampleRate?.takeIf { it > 0 }?.let {
            val k = it / 1000.0
            (if (k % 1.0 == 0.0) "%.0f" else "%.1f").format(k) + " kHz"
        }
        val bits = when (f?.pcmEncoding) {
            C.ENCODING_PCM_16BIT -> "16 bit"
            C.ENCODING_PCM_24BIT -> "24 bit"
            C.ENCODING_PCM_32BIT, C.ENCODING_PCM_FLOAT -> "32 bit"
            else -> null
        }
        return listOfNotNull(name.ifEmpty { null }, bits, rate).joinToString(" · ")
    }
}
