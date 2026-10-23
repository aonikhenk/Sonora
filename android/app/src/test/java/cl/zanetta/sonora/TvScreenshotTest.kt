package cl.zanetta.sonora

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color as AColor
import android.graphics.Paint
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.ui.graphics.asImageBitmap
import com.github.takahirom.roborazzi.captureRoboImage
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

@RunWith(RobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(sdk = [34], qualifiers = "w960dp-h540dp-land-television-xhdpi")
class TvScreenshotTest {
    private val track = Track("od:1", "onedrive://item/1", "Jeff Buckley - Hallelujah", "100 Hits The Best Rock _ Power Ballads",
        "CD5", "od:x", 5, 1, null, 276_000, "flac", Track.SOURCE_ONEDRIVE)
    private val np = NowPlaying(track, isPlaying = true, positionMs = 44_000, durationMs = 276_000, quality = "FLAC · 16 bit · 44.1 kHz")

    private fun art() = Bitmap.createBitmap(800, 800, Bitmap.Config.ARGB_8888).apply {
        val c = Canvas(this); c.drawColor(AColor.rgb(40, 60, 200))
        val p = Paint().apply { color = AColor.WHITE; textSize = 120f; isAntiAlias = true }
        c.drawText("100 HITS", 140f, 400f, p)
    }.asImageBitmap()

    private val lines = Lyrics.parseLrc("""
        [00:20.00]Now I've heard there was a secret chord
        [00:27.00]That David played, and it pleased the Lord
        [00:34.00]But you don't really care for music, do you?
        [00:41.50]It goes like this, the fourth, the fifth
        [00:47.00]The minor falls, the major lifts
        [00:53.00]The baffled king composing Hallelujah
        [01:01.00]Hallelujah, Hallelujah
    """.trimIndent())

    private fun shot(name: String, lyricsOn: Boolean) = captureRoboImage("build/tv/$name.png") {
        MaterialTheme(colorScheme = darkColorScheme(primary = Theme.accent, background = Theme.bg)) {
            TvNowPlaying(np, track, art(), lyricsOn, position = { 44_000 }, onPrev = {}, onToggle = {}, onNext = {},
                onSeekBy = {}, onLyrics = {}, onLibrary = {}, lyricsOverride = LyricsResult(lines, null))
        }
    }

    @Test fun nowPlaying() = shot("reproduciendo", lyricsOn = false)
    @Test fun nowPlayingLyrics() = shot("letra", lyricsOn = true)
}
