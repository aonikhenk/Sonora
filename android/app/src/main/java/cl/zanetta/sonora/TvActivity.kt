package cl.zanetta.sonora

import android.os.Bundle
import android.view.WindowManager
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.runtime.snapshotFlow
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.WindowInsetsControllerCompat
import androidx.lifecycle.lifecycleScope
import kotlinx.coroutines.launch

/** Sonora para Android TV: pantalla completa, manejo con el control remoto. */
class TvActivity : ComponentActivity() {
    val hub = PlayerHub(pollMs = 250)

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        WindowCompat.setDecorFitsSystemWindows(window, false)
        WindowInsetsControllerCompat(window, window.decorView).apply {
            hide(WindowInsetsCompat.Type.systemBars())
            systemBarsBehavior = WindowInsetsControllerCompat.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
        }
        setContent { TvUi(this) }
        hub.connect(this, lifecycleScope)

        // Mientras suena música, la TV no se apaga ni activa el protector de pantalla
        lifecycleScope.launch {
            snapshotFlow { hub.nowPlaying.value.isPlaying && hub.nowPlaying.value.track != null }.collect { playing ->
                if (playing) window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                else window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
            }
        }
    }

    override fun onDestroy() {
        hub.release()
        super.onDestroy()
    }
}
