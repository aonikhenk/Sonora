package cl.zanetta.sonora

import android.Manifest
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.os.Build
import androidx.activity.compose.BackHandler
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsFocusedAsState
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.blur
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.key.Key
import androidx.compose.ui.input.key.KeyEventType
import androidx.compose.ui.input.key.key
import androidx.compose.ui.input.key.onPreviewKeyEvent
import androidx.compose.ui.input.key.type
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.font.Font
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.core.content.ContextCompat
import com.google.zxing.BarcodeFormat
import com.google.zxing.qrcode.QRCodeWriter
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.withContext

private val Adelicia = FontFamily(Font(R.font.adelicia))

private sealed interface TvScreen {
    data object Home : TvScreen
    data object Library : TvScreen
    data class AlbumDetail(val key: String) : TvScreen
    data object Login : TvScreen
    data class Picker(val stack: List<Pair<String?, String>>) : TvScreen
}

// MARK: - Raíz

@Composable
fun TvUi(activity: TvActivity) {
    MaterialTheme(colorScheme = darkColorScheme(primary = Theme.accent, background = Theme.bg, surface = Theme.bar)) {
        var screen by remember { mutableStateOf<TvScreen>(TvScreen.Home) }
        var lyricsOn by rememberSaveable { mutableStateOf(false) }
        val error by Library.error.collectAsState()
        val albums by Library.albums.collectAsState()
        val busy by Library.busy.collectAsState()

        // Al tener biblioteca, completa las carátulas que falten desde Discogs (una vez por sesión)
        var discogsDone by remember { mutableStateOf(false) }
        LaunchedEffect(albums.size, busy) {
            if (!discogsDone && albums.isNotEmpty() && !busy && Discogs.isConfigured) {
                discogsDone = true
                Library.fetchDiscogsCovers(all = false)
            }
        }

        Box(Modifier.fillMaxSize().background(Theme.bg)) {
            @Composable fun Branded(content: @Composable () -> Unit) = Column(Modifier.fillMaxSize()) {
                TvBrandBar(Modifier.padding(start = 56.dp, top = 24.dp))
                Box(Modifier.weight(1f)) { content() }
            }
            when (val s = screen) {
                TvScreen.Home -> TvHome(activity, lyricsOn, onLyrics = { lyricsOn = !lyricsOn },
                    onLibrary = { screen = TvScreen.Library }, onOneDrive = { screen = if (OneDrive.isSignedIn) TvScreen.Picker(listOf(null to "OneDrive")) else TvScreen.Login })
                TvScreen.Library -> {
                    BackHandler { screen = TvScreen.Home }
                    Branded { TvLibrary(onBack = { screen = TvScreen.Home }, onAlbum = { screen = TvScreen.AlbumDetail(it) },
                        onLogin = { screen = TvScreen.Login }, onPicker = { screen = TvScreen.Picker(listOf(null to "OneDrive")) }) }
                }
                is TvScreen.AlbumDetail -> {
                    BackHandler { screen = TvScreen.Library }
                    val album = albums.firstOrNull { it.key == s.key }
                    if (album == null) LaunchedEffect(Unit) { screen = TvScreen.Library }
                    else Branded { TvAlbum(activity, album, onPlay = { screen = TvScreen.Home }) }
                }
                TvScreen.Login -> {
                    BackHandler { screen = TvScreen.Library }
                    Branded { TvLogin(onDone = { screen = TvScreen.Picker(listOf(null to "OneDrive")) }, onCancel = { screen = TvScreen.Library }) }
                }
                is TvScreen.Picker -> {
                    val pop = { screen = if (s.stack.size > 1) TvScreen.Picker(s.stack.dropLast(1)) else TvScreen.Library }
                    BackHandler { pop() }
                    Branded { TvPicker(s.stack.last(), onOpen = { id, name -> screen = TvScreen.Picker(s.stack + (id to name)) },
                        onChoose = { id, name -> Library.useOneDriveFolder(id, name); screen = TvScreen.Library }) }
                }
            }
        }

        val crash = remember {
            java.io.File(activity.filesDir, "crash.txt").takeIf { it.exists() }?.let { f -> f.readText().also { f.delete() } }
        }
        var showCrash by remember { mutableStateOf(crash != null) }
        if (showCrash && crash != null) {
            val lines = crash.lines()
            val summary = (lines.take(3) + lines.filter { "cl.zanetta" in it || it.startsWith("Caused by") }.take(6)).joinToString("\n")
            AlertDialog(
                onDismissRequest = { showCrash = false },
                confirmButton = { TextButton(onClick = { showCrash = false }) { Text("OK", fontSize = 18.sp) } },
                title = { Text("La app se cerró la vez anterior") },
                text = { Text("Saca una foto de este mensaje para corregirlo:\n\n$summary", fontSize = 13.sp, fontFamily = FontFamily.Monospace) },
            )
        }

        error?.let { msg ->
            AlertDialog(
                onDismissRequest = { Library.error.value = null },
                confirmButton = { TextButton(onClick = { Library.error.value = null }) { Text("OK", fontSize = 18.sp) } },
                title = { Text("Sonora") },
                text = { Text(msg, fontSize = 18.sp) },
            )
        }
    }
}

// MARK: - Elementos enfocables con el control remoto

@Composable
private fun Focusable(
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    shape: Shape = RoundedCornerShape(12.dp),
    focusedScale: Float = 1.05f,
    content: @Composable BoxScope.(focused: Boolean) -> Unit,
) {
    val interaction = remember { MutableInteractionSource() }
    val focused by interaction.collectIsFocusedAsState()
    val scale by animateFloatAsState(if (focused) focusedScale else 1f, label = "focus")
    Box(
        modifier
            .graphicsLayer { scaleX = scale; scaleY = scale }
            .clip(shape)
            .border(3.dp, if (focused) Color.White else Color.Transparent, shape)
            .clickable(interactionSource = interaction, indication = null, onClick = onClick),
    ) { content(focused) }
}

@Composable
private fun TvButton(text: String, onClick: () -> Unit, modifier: Modifier = Modifier, primary: Boolean = false, icon: androidx.compose.ui.graphics.vector.ImageVector? = null) {
    Focusable(onClick, modifier, RoundedCornerShape(30.dp)) { focused ->
        Row(
            Modifier.background(if (focused) Color.White else if (primary) Theme.accent else Color.White.copy(alpha = 0.1f))
                .padding(horizontal = 22.dp, vertical = 12.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            val fg = if (focused || primary) Theme.bg else Color.White
            if (icon != null) { Icon(icon, null, Modifier.size(22.dp), tint = fg); Spacer(Modifier.width(10.dp)) }
            Text(text, color = fg, fontSize = 17.sp, fontWeight = FontWeight.SemiBold, maxLines = 1, softWrap = false)
        }
    }
}

@Composable
private fun RoundControl(icon: androidx.compose.ui.graphics.vector.ImageVector, desc: String, size: Dp, onClick: () -> Unit,
                         modifier: Modifier = Modifier, active: Boolean = false) {
    Focusable(onClick, modifier, RoundedCornerShape(50), focusedScale = 1.12f) { focused ->
        Box(Modifier.size(size).background(when { focused -> Color.White; active -> Theme.accent; else -> Color.White.copy(alpha = 0.08f) }),
            contentAlignment = Alignment.Center) {
            Icon(icon, desc, Modifier.size(size * 0.5f), tint = if (focused || active) Theme.bg else Color.White)
        }
    }
}

@Composable
private fun rememberTvArtwork(albumKey: String?, maxPx: Int = 1600): ImageBitmap? {
    val albums by Library.albums.collectAsState()
    val version by Library.artVersion.collectAsState()
    val album = albums.firstOrNull { it.key == albumKey }
    val art by produceState<ImageBitmap?>(null, album?.key, version) {
        value = album?.let { a -> withContext(Dispatchers.IO) { Library.artwork(a, maxPx)?.asImageBitmap() } }
    }
    return art
}

// MARK: - Inicio / Reproduciendo

@Composable
private fun TvHome(activity: TvActivity, lyricsOn: Boolean, onLyrics: () -> Unit, onLibrary: () -> Unit, onOneDrive: () -> Unit) {
    val np by activity.hub.nowPlaying
    val t = np.track
    if (t == null) {
        TvIdle(onLibrary, onOneDrive)
        return
    }
    val art = rememberTvArtwork(t.albumKey)
    TvNowPlaying(
        np = np, t = t, art = art, lyricsOn = lyricsOn,
        position = { activity.hub.position() },
        onPrev = { activity.hub.previous() }, onToggle = { activity.hub.togglePlay() }, onNext = { activity.hub.next() },
        onSeekBy = { activity.hub.seekBy(it) }, onLyrics = onLyrics, onLibrary = onLibrary,
    )
}

/** Logo y nombre, siempre visibles arriba a la izquierda. */
@Composable
fun TvBrandBar(modifier: Modifier = Modifier) {
    Row(modifier, verticalAlignment = Alignment.CenterVertically) {
        Image(painterResource(R.drawable.logo), null, Modifier.size(46.dp))
        Spacer(Modifier.width(12.dp))
        Text("Sonora", color = Color.White, fontSize = 40.sp, fontFamily = Adelicia)
    }
}

/** Pantalla de reproducción (sin dependencias del reproductor, para poder probarla). */
@Composable
fun TvNowPlaying(
    np: NowPlaying,
    t: Track,
    art: ImageBitmap?,
    lyricsOn: Boolean,
    position: () -> Long,
    onPrev: () -> Unit,
    onToggle: () -> Unit,
    onNext: () -> Unit,
    onSeekBy: (Long) -> Unit,
    onLyrics: () -> Unit,
    onLibrary: () -> Unit,
    lyricsOverride: LyricsResult? = null,
) {
    val playFocus = remember { FocusRequester() }
    LaunchedEffect(t.id) { runCatching { playFocus.requestFocus() } }

    Box(Modifier.fillMaxSize().background(Theme.bg)) {
        // Fondo: la carátula ampliada y desenfocada
        if (art != null) {
            Image(art, null, Modifier.fillMaxSize().then(if (Build.VERSION.SDK_INT >= 31) Modifier.blur(60.dp) else Modifier),
                contentScale = ContentScale.Crop, alpha = if (Build.VERSION.SDK_INT >= 31) 0.5f else 0.15f)
        }
        Box(Modifier.fillMaxSize().background(Brush.horizontalGradient(listOf(Color.Black.copy(alpha = 0.35f), Theme.bg.copy(alpha = 0.9f)))))

        Column(Modifier.fillMaxSize().padding(horizontal = 56.dp, vertical = 28.dp)) {
            TvBrandBar()
            Spacer(Modifier.height(18.dp))
            Row(Modifier.weight(1f).fillMaxWidth()) {
                // Carátula: tan alta como el espacio disponible
                Box(Modifier.fillMaxHeight().aspectRatio(1f).shadow(30.dp, RoundedCornerShape(10.dp)).clip(RoundedCornerShape(10.dp)).background(Theme.bar),
                    contentAlignment = Alignment.Center) {
                    if (art != null) Image(art, null, Modifier.fillMaxSize(), contentScale = ContentScale.Crop)
                    else Image(painterResource(R.drawable.logo), null, Modifier.fillMaxSize(0.5f), alpha = 0.6f)
                    if (np.buffering) {
                        Box(Modifier.fillMaxSize().background(Color.Black.copy(alpha = 0.45f)), contentAlignment = Alignment.Center) {
                            CircularProgressIndicator(color = Color.White)
                        }
                    }
                }
                Spacer(Modifier.width(48.dp))

                Column(Modifier.weight(1f).fillMaxHeight()) {
                    if (np.quality.isNotEmpty()) {
                        Text(np.quality, color = Theme.accent, fontSize = 15.sp, fontWeight = FontWeight.SemiBold, fontFamily = FontFamily.Monospace)
                        Spacer(Modifier.height(8.dp))
                    }
                    Text(t.title, color = Color.White, fontSize = if (lyricsOn) 26.sp else 38.sp, fontWeight = FontWeight.Bold,
                        lineHeight = if (lyricsOn) 32.sp else 44.sp, maxLines = 2, overflow = TextOverflow.Ellipsis)
                    Spacer(Modifier.height(6.dp))
                    Text(listOf(t.artist, t.album).filter { it.isNotBlank() }.joinToString(" · "), color = Theme.dim,
                        fontSize = if (lyricsOn) 17.sp else 22.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)

                    // Zona de la letra: ocupa todo el espacio libre entre el título y los controles
                    Box(Modifier.weight(1f).fillMaxWidth().padding(vertical = 14.dp)) {
                        if (lyricsOn) LyricsPanel(t, np, position, lyricsOverride)
                    }

                    TvProgress(np, onSeekBy, onToggle)
                    Spacer(Modifier.height(16.dp))
                    Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                        RoundControl(Icons.prev, "Anterior", 54.dp, onPrev)
                        RoundControl(if (np.isPlaying) Icons.pause else Icons.play, "Reproducir", 68.dp, onToggle, Modifier.focusRequester(playFocus))
                        RoundControl(Icons.next, "Siguiente", 54.dp, onNext)
                        Spacer(Modifier.weight(1f))
                        RoundControl(Icons.lyrics, if (lyricsOn) "Ocultar letra" else "Letra", 54.dp, onLyrics, active = lyricsOn)
                        RoundControl(Icons.note, "Biblioteca", 54.dp, onLibrary)
                    }
                }
            }
        }
    }
}

@Composable
private fun TvProgress(np: NowPlaying, onSeekBy: (Long) -> Unit, onToggle: () -> Unit) {
    val frac = if (np.durationMs > 0) (np.positionMs.toFloat() / np.durationMs).coerceIn(0f, 1f) else 0f
    val interaction = remember { MutableInteractionSource() }
    val focused by interaction.collectIsFocusedAsState()
    Column {
        Canvas(
            Modifier.fillMaxWidth().height(20.dp)
                .onPreviewKeyEvent { e ->
                    if (e.type != KeyEventType.KeyDown) return@onPreviewKeyEvent false
                    when (e.key) {
                        Key.DirectionLeft -> { onSeekBy(-10_000); true }
                        Key.DirectionRight -> { onSeekBy(10_000); true }
                        else -> false
                    }
                }
                .clickable(interactionSource = interaction, indication = null) { onToggle() }
        ) {
            val h = if (focused) 8f else 5f
            val y = size.height / 2
            drawRoundRect(Color.White.copy(alpha = 0.2f), Offset(0f, y - h / 2), Size(size.width, h), CornerRadius(h))
            drawRoundRect(if (focused) Theme.accent else Color.White, Offset(0f, y - h / 2), Size(size.width * frac, h), CornerRadius(h))
            if (focused) drawCircle(Color.White, 12f, Offset(size.width * frac, y))
        }
        Row(Modifier.fillMaxWidth()) {
            Text(formatTime(np.positionMs), color = Theme.dim, fontSize = 15.sp)
            Text(if (focused) "◀ ▶  10 s" else "", color = Theme.dim, fontSize = 13.sp, textAlign = TextAlign.Center, modifier = Modifier.weight(1f))
            Text("-" + formatTime(np.durationMs - np.positionMs), color = Theme.dim, fontSize = 15.sp)
        }
    }
}

@Composable
private fun TvIdle(onLibrary: () -> Unit, onOneDrive: () -> Unit) {
    val first = remember { FocusRequester() }
    LaunchedEffect(Unit) { runCatching { first.requestFocus() } }
    Column(Modifier.fillMaxSize(), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.Center) {
        Image(painterResource(R.drawable.logo), "Sonora", Modifier.size(220.dp))
        Text("Sonora", color = Color.White, fontSize = 64.sp, fontFamily = Adelicia)
        Spacer(Modifier.height(36.dp))
        Row(horizontalArrangement = Arrangement.spacedBy(20.dp)) {
            TvButton("Biblioteca", onLibrary, Modifier.focusRequester(first), primary = true, icon = Icons.note)
            TvButton(if (OneDrive.isSignedIn) "Carpeta de OneDrive" else "Conectar OneDrive", onOneDrive, icon = Icons.folder)
        }
    }
}

// MARK: - Letras sincronizadas (LRCLIB)

@Composable
private fun LyricsPanel(t: Track, np: NowPlaying, position: () -> Long, override: LyricsResult? = null) {
    val known = np.durationMs > 0
    val lyrics by produceState(override, t.id, known) {
        if (override != null) return@produceState
        value = null
        value = withContext(Dispatchers.IO) { runCatching { Lyrics.fetch(t, np.durationMs) }.getOrNull() } ?: LyricsResult(null, null)
    }
    val l = lyrics
    when {
        l == null -> Text("Buscando letra…", color = Theme.dim, fontSize = 22.sp)
        l.instrumental -> Text("Instrumental", color = Theme.dim, fontSize = 26.sp)
        !l.synced.isNullOrEmpty() -> SyncedLyrics(position, l.synced)
        !l.plain.isNullOrBlank() -> PlainLyrics(l.plain, np)
        else -> Text("No se encontró la letra de esta canción en LRCLIB.", color = Theme.dim, fontSize = 22.sp)
    }
}

@Composable
private fun SyncedLyrics(position: () -> Long, lines: List<LyricLine>) {
    var pos by remember { mutableLongStateOf(position()) }
    LaunchedEffect(lines) {
        while (isActive) {
            pos = position()
            delay(120)
        }
    }
    val current = lines.indexOfLast { it.timeMs <= pos + 150 }.coerceAtLeast(0)
    val state = rememberLazyListState()
    LaunchedEffect(current) { state.animateScrollToItem((current - 1).coerceAtLeast(0)) }
    LazyColumn(state = state, userScrollEnabled = false, modifier = Modifier.fillMaxSize()) {
        itemsIndexed(lines) { i, line ->
            val active = i == current
            Text(
                line.text.ifBlank { "♪" },
                color = when {
                    active -> Color.White
                    i < current -> Color.White.copy(alpha = 0.35f)
                    else -> Color.White.copy(alpha = 0.55f)
                },
                fontSize = if (active) 28.sp else 21.sp,
                fontWeight = if (active) FontWeight.Bold else FontWeight.Medium,
                lineHeight = if (active) 35.sp else 28.sp,
                modifier = Modifier.padding(vertical = 5.dp),
            )
        }
        item { Spacer(Modifier.height(200.dp)) }
    }
}

@Composable
private fun PlainLyrics(text: String, np: NowPlaying) {
    // Sin tiempos: avanza en proporción a la canción
    val scroll = rememberScrollState()
    val frac = if (np.durationMs > 0) np.positionMs.toFloat() / np.durationMs else 0f
    LaunchedEffect((frac * 100).toInt()) { scroll.animateScrollTo((scroll.maxValue * frac).toInt()) }
    Column(Modifier.fillMaxSize().verticalScroll(scroll, enabled = false)) {
        Text("Letra sin sincronizar", color = Theme.accent, fontSize = 14.sp)
        Spacer(Modifier.height(8.dp))
        Text(text, color = Color.White.copy(alpha = 0.85f), fontSize = 22.sp, lineHeight = 32.sp)
    }
}

// MARK: - Biblioteca

@Composable
private fun TvLibrary(onBack: () -> Unit, onAlbum: (String) -> Unit, onLogin: () -> Unit, onPicker: () -> Unit) {
    val albums by Library.albums.collectAsState()
    val busy by Library.busy.collectAsState()
    val status by Library.status.collectAsState()
    val context = LocalContext.current
    val permission = if (Build.VERSION.SDK_INT >= 33) Manifest.permission.READ_MEDIA_AUDIO else Manifest.permission.READ_EXTERNAL_STORAGE
    val ask = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { ok ->
        if (ok) Library.refreshLocal() else Library.error.value = "Sin permiso no se puede leer la música de este dispositivo."
    }
    val deviceMusic = {
        if (ContextCompat.checkSelfPermission(context, permission) == PackageManager.PERMISSION_GRANTED) Library.refreshLocal()
        else ask.launch(permission)
    }
    val first = remember { FocusRequester() }
    LaunchedEffect(Unit) { runCatching { first.requestFocus() } }
    val signedIn = remember(albums, busy) { OneDrive.isSignedIn }

    Column(Modifier.fillMaxSize().padding(horizontal = 48.dp, vertical = 16.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text("Biblioteca", color = Color.White, fontSize = 30.sp, fontWeight = FontWeight.Bold)
            Spacer(Modifier.width(28.dp))
            Row(Modifier.weight(1f).horizontalScroll(rememberScrollState()), verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(14.dp, Alignment.End)) {
            TvButton("Volver", onBack, Modifier.focusRequester(first), icon = Icons.back)
            if (signedIn) {
                TvButton(OneDrive.folderName?.let { "OneDrive: $it" } ?: "Elegir carpeta", onPicker, icon = Icons.folder)
                TvButton("Actualizar", { Library.refreshOneDrive() })
            } else TvButton("Conectar OneDrive", onLogin, primary = true, icon = Icons.folder)
            TvButton("Este dispositivo", deviceMusic)
            if (Discogs.isConfigured) TvButton("Carátulas HD", { Library.fetchDiscogsCovers(all = true) })
            }
        }
        Spacer(Modifier.height(10.dp))
        Row(verticalAlignment = Alignment.CenterVertically) {
            if (busy) { CircularProgressIndicator(Modifier.size(18.dp), strokeWidth = 2.dp); Spacer(Modifier.width(10.dp)) }
            Text(if (busy) status else "${albums.size} álbumes", color = Theme.dim, fontSize = 15.sp)
            Spacer(Modifier.weight(1f))
            if (Discogs.isConfigured) Text("Carátulas: Discogs · Letras: LRCLIB", color = Theme.dim.copy(alpha = 0.6f), fontSize = 12.sp)
        }
        Spacer(Modifier.height(16.dp))
        if (albums.isEmpty() && !busy) {
            Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                Text("Conecta OneDrive o usa la música de este dispositivo", color = Theme.dim, fontSize = 22.sp)
            }
            return@Column
        }
        LazyVerticalGrid(GridCells.Adaptive(180.dp), horizontalArrangement = Arrangement.spacedBy(24.dp),
            verticalArrangement = Arrangement.spacedBy(24.dp), contentPadding = PaddingValues(8.dp)) {
            items(albums, key = { it.key }) { a -> AlbumCard(a) { onAlbum(a.key) } }
        }
    }
}

@Composable
private fun AlbumCard(a: Album, onClick: () -> Unit) {
    val art = rememberTvArtwork(a.key, 500)
    Focusable(onClick, shape = RoundedCornerShape(10.dp), focusedScale = 1.08f) { focused ->
        Column(Modifier.background(if (focused) Color.White.copy(alpha = 0.12f) else Color.Transparent).padding(8.dp)) {
            Box(Modifier.fillMaxWidth().aspectRatio(1f).clip(RoundedCornerShape(6.dp)).background(Theme.bar), contentAlignment = Alignment.Center) {
                if (art != null) Image(art, null, Modifier.fillMaxSize(), contentScale = ContentScale.Crop)
                else Icon(Icons.note, null, Modifier.size(48.dp), tint = Theme.dim)
            }
            Spacer(Modifier.height(8.dp))
            Text(a.title, color = Color.White, fontSize = 16.sp, fontWeight = FontWeight.SemiBold, maxLines = 1, overflow = TextOverflow.Ellipsis)
            Text(listOfNotNull(a.artist, a.year).joinToString(" · "), color = Theme.dim, fontSize = 13.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
        }
    }
}

// MARK: - Álbum

@Composable
private fun TvAlbum(activity: TvActivity, album: Album, onPlay: () -> Unit) {
    val np by activity.hub.nowPlaying
    val art = rememberTvArtwork(album.key, 1000)
    val offline by Library.offlineState.collectAsState()
    val downloads by Library.downloads.collectAsState()
    val playFocus = remember { FocusRequester() }
    LaunchedEffect(album.key) { runCatching { playFocus.requestFocus() } }

    Row(Modifier.fillMaxSize().padding(horizontal = 56.dp, vertical = 40.dp)) {
        Column(Modifier.width(360.dp)) {
            Box(Modifier.size(360.dp).clip(RoundedCornerShape(10.dp)).background(Theme.bar), contentAlignment = Alignment.Center) {
                if (art != null) Image(art, null, Modifier.fillMaxSize(), contentScale = ContentScale.Crop)
                else Icon(Icons.note, null, Modifier.size(80.dp), tint = Theme.dim)
            }
            Spacer(Modifier.height(18.dp))
            Text(album.title, color = Color.White, fontSize = 26.sp, fontWeight = FontWeight.Bold, maxLines = 2, overflow = TextOverflow.Ellipsis)
            Text(album.artist, color = Theme.dim, fontSize = 18.sp)
            Text(listOfNotNull(album.year, "${album.tracks.size} canciones", album.totalMs.takeIf { it > 0 }?.let(::formatTime),
                if (album.isOneDrive) "OneDrive" else null).joinToString(" · "), color = Theme.dim, fontSize = 14.sp)
            Spacer(Modifier.height(20.dp))
            Row(horizontalArrangement = Arrangement.spacedBy(14.dp)) {
                TvButton("Reproducir", { activity.hub.play(album, 0); onPlay() }, Modifier.focusRequester(playFocus), primary = true, icon = Icons.play)
                if (album.isOneDrive) {
                    val p = downloads[album.key]
                    val saved = album.tracks.count { it.id in offline }
                    when {
                        p != null -> TvButton("Descargando ${p.first}/${p.second}", {})
                        saved == album.tracks.size -> TvButton("En la TV ✓", { Library.removeDownload(album) })
                        else -> TvButton("Descargar", { Library.download(album) }, icon = Icons.down)
                    }
                }
            }
        }
        Spacer(Modifier.width(48.dp))
        LazyColumn(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp), contentPadding = PaddingValues(vertical = 8.dp)) {
            itemsIndexed(album.tracks, key = { _, t -> t.id }) { i, t ->
                val current = np.track?.id == t.id
                Focusable({ activity.hub.play(album, i); onPlay() }, Modifier.fillMaxWidth(), RoundedCornerShape(8.dp), focusedScale = 1.02f) { focused ->
                    Row(Modifier.fillMaxWidth().background(if (focused) Color.White.copy(alpha = 0.14f) else Color.Transparent)
                        .padding(horizontal = 18.dp, vertical = 14.dp), verticalAlignment = Alignment.CenterVertically) {
                        Text(if (current) "♪" else "%02d".format(t.trackNumber), color = if (current) Theme.accent else Theme.dim,
                            fontSize = 18.sp, modifier = Modifier.width(44.dp))
                        Text(t.title, color = if (current) Theme.accent else Color.White, fontSize = 20.sp, maxLines = 1,
                            overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f))
                        if (t.durationMs > 0) Text(formatTime(t.durationMs), color = Theme.dim, fontSize = 17.sp)
                    }
                }
            }
        }
    }
}

// MARK: - OneDrive: inicio de sesión con código

@Composable
private fun TvLogin(onDone: () -> Unit, onCancel: () -> Unit) {
    var code by remember { mutableStateOf<OneDrive.DeviceCode?>(null) }
    var err by remember { mutableStateOf<String?>(null) }
    val focus = remember { FocusRequester() }
    LaunchedEffect(Unit) {
        try {
            val c = withContext(Dispatchers.IO) { OneDrive.startDeviceLogin() }
            code = c
            runCatching { focus.requestFocus() }
            while (isActive && System.currentTimeMillis() < c.expiresAt) {
                delay(c.intervalSec * 1000L)
                if (withContext(Dispatchers.IO) { OneDrive.pollDeviceLogin(c) }) { onDone(); return@LaunchedEffect }
            }
            err = "El código expiró. Vuelve a intentarlo."
        } catch (e: Exception) {
            err = e.message
        }
    }
    Row(Modifier.fillMaxSize().padding(72.dp), verticalAlignment = Alignment.CenterVertically) {
        Column(Modifier.weight(1f)) {
            Text("Conectar OneDrive", color = Color.White, fontSize = 38.sp, fontWeight = FontWeight.Bold)
            Spacer(Modifier.height(24.dp))
            val c = code
            when {
                err != null -> Text(err!!, color = Color(0xFFFF8A8A), fontSize = 22.sp)
                c == null -> CircularProgressIndicator()
                else -> {
                    Text("1. En tu teléfono o computador abre:", color = Theme.dim, fontSize = 22.sp)
                    Text(c.verificationUri.removePrefix("https://"), color = Color.White, fontSize = 30.sp, fontWeight = FontWeight.SemiBold)
                    Spacer(Modifier.height(18.dp))
                    Text("2. Escribe este código:", color = Theme.dim, fontSize = 22.sp)
                    Text(c.userCode, color = Theme.accent, fontSize = 56.sp, fontWeight = FontWeight.Bold, letterSpacing = 6.sp,
                        fontFamily = FontFamily.Monospace)
                    Spacer(Modifier.height(18.dp))
                    Text("3. Inicia sesión con tu cuenta de Microsoft. Esta pantalla avanzará sola.", color = Theme.dim, fontSize = 20.sp)
                }
            }
            Spacer(Modifier.height(30.dp))
            TvButton("Cancelar", onCancel, Modifier.focusRequester(focus))
        }
        code?.let { c ->
            val qr = remember(c.verificationUri) { qrBitmap(c.verificationUri, 600) }
            Column(horizontalAlignment = Alignment.CenterHorizontally) {
                Image(qr, "Código QR", Modifier.size(300.dp).clip(RoundedCornerShape(12.dp)))
                Spacer(Modifier.height(10.dp))
                Text("O escanea con la cámara del teléfono", color = Theme.dim, fontSize = 16.sp)
            }
        }
    }
}

private fun qrBitmap(text: String, size: Int): ImageBitmap {
    val m = QRCodeWriter().encode(text, BarcodeFormat.QR_CODE, size, size)
    val px = IntArray(size * size) { i -> if (m[i % size, i / size]) 0xFF13152A.toInt() else 0xFFFFFFFF.toInt() }
    return Bitmap.createBitmap(px, size, size, Bitmap.Config.ARGB_8888).asImageBitmap()
}

// MARK: - OneDrive: elegir carpeta

@Composable
private fun TvPicker(here: Pair<String?, String>, onOpen: (String, String) -> Unit, onChoose: (String, String) -> Unit) {
    val (id, name) = here
    var items by remember(id) { mutableStateOf<List<DriveItem>?>(null) }
    var err by remember(id) { mutableStateOf<String?>(null) }
    val focus = remember(id) { FocusRequester() }
    LaunchedEffect(id) {
        try { items = withContext(Dispatchers.IO) { OneDrive.children(id) }.filter { it.isFolder }.sortedBy { it.name.lowercase() } }
        catch (e: Exception) { err = e.message }
    }
    LaunchedEffect(items) { if (items != null) runCatching { focus.requestFocus() } }
    Column(Modifier.fillMaxSize().padding(horizontal = 72.dp, vertical = 40.dp)) {
        Text(name, color = Color.White, fontSize = 34.sp, fontWeight = FontWeight.Bold)
        Text(if (id == null) "Entra a tu carpeta de música con el control remoto" else "Atrás para volver", color = Theme.dim, fontSize = 18.sp)
        Spacer(Modifier.height(20.dp))
        if (id != null) {
            TvButton("Usar \"$name\" como biblioteca", { onChoose(id, name) }, Modifier.focusRequester(focus), primary = true)
            Spacer(Modifier.height(16.dp))
        }
        when {
            err != null -> Text(err!!, color = Color(0xFFFF8A8A), fontSize = 20.sp)
            items == null -> CircularProgressIndicator()
            else -> LazyColumn(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                itemsIndexed(items!!, key = { _, f -> f.id }) { i, f ->
                    Focusable({ onOpen(f.id, f.name) }, (if (id == null && i == 0) Modifier.focusRequester(focus) else Modifier).fillMaxWidth(0.6f),
                        RoundedCornerShape(8.dp), focusedScale = 1.02f) { focused ->
                        Row(Modifier.fillMaxWidth().background(if (focused) Color.White.copy(alpha = 0.14f) else Color.Transparent)
                            .padding(horizontal = 18.dp, vertical = 14.dp), verticalAlignment = Alignment.CenterVertically) {
                            Icon(Icons.folder, null, Modifier.size(26.dp), tint = Theme.accent)
                            Spacer(Modifier.width(16.dp))
                            Text(f.name, color = Color.White, fontSize = 20.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
                        }
                    }
                }
            }
        }
    }
}
