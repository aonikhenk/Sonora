package cl.zanetta.sonora

import android.Manifest
import android.content.pm.PackageManager
import android.os.Build
import androidx.activity.compose.BackHandler
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectHorizontalDragGestures
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.graphics.vector.addPathNodes
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.Font
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.core.content.ContextCompat
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

// MARK: - Tema

object Theme {
    val bg = Color(0xFF13152A)
    val bar = Color(0xFF0F1019)
    val accent = Color(0xFF7D8AE0)
    val dim = Color(0x80FFFFFF)
    val line = Color(0x12FFFFFF)
}

object Icons {
    private fun icon(d: String) = ImageVector.Builder(defaultWidth = 24.dp, defaultHeight = 24.dp, viewportWidth = 24f, viewportHeight = 24f)
        .addPath(addPathNodes(d), fill = SolidColor(Color.White)).build()

    val play = icon("M8,5v14l11,-7z")
    val pause = icon("M6,19h4V5H6v14zM14,5v14h4V5h-4z")
    val next = icon("M6,18l8.5,-6L6,6v12zM16,6v12h2V6h-2z")
    val prev = icon("M6,6h2v12H6zM9.5,12l8.5,6V6z")
    val note = icon("M12,3v10.55c-0.59,-0.34 -1.27,-0.55 -2,-0.55 -2.21,0 -4,1.79 -4,4s1.79,4 4,4 4,-1.79 4,-4V7h4V3h-6z")
    val back = icon("M20,11H7.83l5.59,-5.59L12,4l-8,8 8,8 1.41,-1.41L7.83,13H20v-2z")
    val add = icon("M19,13h-6v6h-2v-6H5v-2h6V5h2v6h6v2z")
    val folder = icon("M10,4H4c-1.1,0 -1.99,0.9 -1.99,2L2,18c0,1.1 0.9,2 2,2h16c1.1,0 2,-0.9 2,-2V8c0,-1.1 -0.9,-2 -2,-2h-8l-2,-2z")
    val down = icon("M20,12l-1.41,-1.41L13,16.17V4h-2v12.17l-5.58,-5.59L4,12l8,8 8,-8z")
    val check = icon("M9,16.17L4.83,12l-1.42,1.41L9,19 21,7l-1.41,-1.41z")
    val speaker = icon("M3,9v6h4l5,5V4L7,9H3zM16.5,12c0,-1.77 -1.02,-3.29 -2.5,-4.03v8.05c1.48,-0.73 2.5,-2.25 2.5,-4.02z")
}

private sealed interface Screen {
    data object Main : Screen
    data object Albums : Screen
    data class AlbumDetail(val key: String) : Screen
    data class Picker(val stack: List<Pair<String?, String>>) : Screen
}

// MARK: - Raíz

@Composable
fun SonoraUi(activity: MainActivity) {
    MaterialTheme(colorScheme = darkColorScheme(primary = Theme.accent, background = Theme.bg, surface = Theme.bar)) {
        var screen by remember { mutableStateOf<Screen>(Screen.Main) }
        val pick by activity.pickOneDriveFolder
        LaunchedEffect(pick) {
            if (pick) {
                screen = Screen.Picker(listOf(null to "OneDrive"))
                activity.pickOneDriveFolder.value = false
            }
        }
        val error by Library.error.collectAsState()

        Box(Modifier.fillMaxSize().background(Theme.bg).systemBarsPadding()) {
            when (val s = screen) {
                Screen.Main -> MainScreen(activity) { screen = Screen.Albums }
                Screen.Albums -> {
                    BackHandler { screen = Screen.Main }
                    AlbumsScreen(activity, onBack = { screen = Screen.Main }, onAlbum = { screen = Screen.AlbumDetail(it) },
                        onPickFolder = { screen = Screen.Picker(listOf(null to "OneDrive")) })
                }
                is Screen.AlbumDetail -> {
                    BackHandler { screen = Screen.Albums }
                    val album = Library.albums.collectAsState().value.firstOrNull { it.key == s.key }
                    if (album == null) LaunchedEffect(Unit) { screen = Screen.Albums }
                    else AlbumScreen(activity, album, onBack = { screen = Screen.Albums }, onPlay = { screen = Screen.Main })
                }
                is Screen.Picker -> {
                    val pop = { screen = if (s.stack.size > 1) Screen.Picker(s.stack.dropLast(1)) else Screen.Albums }
                    BackHandler { pop() }
                    FolderPicker(s.stack.last(), onBack = pop,
                        onOpen = { id, name -> screen = Screen.Picker(s.stack + (id to name)) },
                        onChoose = { id, name ->
                            Library.useOneDriveFolder(id, name)
                            screen = Screen.Albums
                        })
                }
            }
        }

        activity.crashReport.value?.let { report ->
            // Resumen corto: tipo de error + primeras líneas de Sonora
            val lines = report.lines()
            val summary = (lines.take(4) + lines.filter { "cl.zanetta" in it || it.startsWith("Caused by") }.take(6)).joinToString("\n")
            AlertDialog(
                onDismissRequest = { activity.crashReport.value = null },
                title = { Text("La app se cerró") },
                text = {
                    Box(Modifier.heightIn(max = 360.dp).verticalScroll(rememberScrollState())) {
                        Text("Comparte este informe para corregirlo:\n\n$summary", fontSize = 11.sp, fontFamily = FontFamily.Monospace)
                    }
                },
                confirmButton = { TextButton(onClick = { activity.shareCrash(report) }) { Text("Compartir") } },
                dismissButton = {
                    Row {
                        TextButton(onClick = { activity.copyCrash(report) }) { Text("Copiar") }
                        TextButton(onClick = { activity.crashReport.value = null }) { Text("Cerrar") }
                    }
                },
            )
        }

        error?.let { msg ->
            AlertDialog(
                onDismissRequest = { Library.error.value = null },
                confirmButton = { TextButton(onClick = { Library.error.value = null }) { Text("OK") } },
                title = { Text("Sonora") },
                text = { Box(Modifier.heightIn(max = 420.dp).verticalScroll(rememberScrollState())) { Text(msg, fontSize = 12.sp) } },
            )
        }
    }
}

// MARK: - Pantalla principal

@Composable
private fun MainScreen(activity: MainActivity, openLibrary: () -> Unit) {
    val np by activity.nowPlaying
    Column(Modifier.fillMaxSize(), horizontalAlignment = Alignment.CenterHorizontally) {
        val t = np.track
        if (t == null) {
            Box(Modifier.weight(1f), contentAlignment = Alignment.Center) { Logo() }
        } else {
            Spacer(Modifier.weight(1f))
            Artwork(t, np.buffering)
            Spacer(Modifier.weight(1f))
            Controls(activity, np, t)
        }
        IconButton(onClick = openLibrary, modifier = Modifier.padding(top = 6.dp, bottom = 8.dp).size(64.dp)) {
            Icon(Icons.note, "Biblioteca", tint = Color.White.copy(alpha = 0.85f), modifier = Modifier.size(30.dp))
        }
    }
}

@Composable
private fun Logo() {
    Column(horizontalAlignment = Alignment.CenterHorizontally) {
        Image(painterResource(R.drawable.logo), "Sonora", Modifier.size(200.dp))
        Spacer(Modifier.height(12.dp))
        Text("Sonora", color = Color.White.copy(alpha = 0.9f), fontSize = 44.sp, fontFamily = FontFamily(Font(R.font.adelicia)))
    }
}

@Composable
private fun rememberArtwork(albumKey: String): ImageBitmap? {
    val albums by Library.albums.collectAsState()
    val album = albums.firstOrNull { it.key == albumKey }
    val version by Library.artVersion.collectAsState()
    val art by produceState<ImageBitmap?>(null, album, version) {
        value = album?.let { a -> withContext(Dispatchers.IO) { Library.artwork(a)?.asImageBitmap() } }
    }
    return art
}

@Composable
private fun Artwork(t: Track, loading: Boolean) {
    val art = rememberArtwork(t.albumKey)
    Box(Modifier.fillMaxWidth().aspectRatio(1f).shadow(24.dp).background(Theme.bar), contentAlignment = Alignment.Center) {
        if (art != null) Image(art, null, Modifier.fillMaxSize(), contentScale = ContentScale.Crop)
        else Image(painterResource(R.drawable.logo), null, Modifier.fillMaxSize(0.5f).padding(8.dp), alpha = 0.5f)
        if (loading) {
            Box(Modifier.fillMaxSize().background(Color.Black.copy(alpha = 0.45f)), contentAlignment = Alignment.Center) {
                Column(horizontalAlignment = Alignment.CenterHorizontally) {
                    CircularProgressIndicator(color = Color.White, strokeWidth = 2.dp)
                    Spacer(Modifier.height(10.dp))
                    Text("Cargando…", color = Color.White.copy(alpha = 0.85f), fontSize = 13.sp)
                }
            }
        }
    }
}

@Composable
private fun Controls(activity: MainActivity, np: NowPlaying, t: Track) {
    var drag by remember { mutableStateOf<Float?>(null) }
    val frac = drag ?: if (np.durationMs > 0) (np.positionMs.toFloat() / np.durationMs).coerceIn(0f, 1f) else 0f
    Column(Modifier.padding(horizontal = 28.dp), horizontalAlignment = Alignment.CenterHorizontally) {
        // Barra de avance
        Canvas(
            Modifier.fillMaxWidth().height(24.dp)
                .pointerInput(np.durationMs) {
                    detectTapGestures { activity.seek((it.x / size.width * np.durationMs).toLong()) }
                }
                .pointerInput(np.durationMs) {
                    detectHorizontalDragGestures(
                        onDragStart = { drag = (it.x / size.width).coerceIn(0f, 1f) },
                        onDragEnd = { drag?.let { activity.seek((it * np.durationMs).toLong()) }; drag = null },
                        onDragCancel = { drag = null },
                        onHorizontalDrag = { ch, _ -> drag = (ch.position.x / size.width).coerceIn(0f, 1f) },
                    )
                }
        ) {
            val y = size.height / 2
            drawRoundRect(Color.White.copy(alpha = 0.18f), Offset(0f, y - 1.5f), Size(size.width, 3f), CornerRadius(2f))
            drawRoundRect(Color.White.copy(alpha = 0.9f), Offset(0f, y - 1.5f), Size(size.width * frac, 3f), CornerRadius(2f))
        }
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
            Text(formatTime((frac * np.durationMs).toLong()), color = Theme.dim, fontSize = 11.sp)
            Text(np.quality, color = Theme.accent, fontSize = 10.sp, fontFamily = FontFamily.Monospace,
                fontWeight = FontWeight.SemiBold, textAlign = TextAlign.Center, modifier = Modifier.weight(1f))
            Text("-" + formatTime(((1 - frac) * np.durationMs).toLong()), color = Theme.dim, fontSize = 11.sp)
        }
        Spacer(Modifier.height(14.dp))
        Text(t.title, color = Color.White, fontSize = 20.sp, fontWeight = FontWeight.SemiBold, maxLines = 1, overflow = TextOverflow.Ellipsis)
        Spacer(Modifier.height(4.dp))
        Text(listOf(t.artist, t.album).filter { it.isNotBlank() }.joinToString(" · "), color = Theme.dim, fontSize = 14.sp,
            maxLines = 1, overflow = TextOverflow.Ellipsis)
        Spacer(Modifier.height(16.dp))
        Row(horizontalArrangement = Arrangement.spacedBy(40.dp), verticalAlignment = Alignment.CenterVertically) {
            IconButton(onClick = { activity.previous() }, Modifier.size(64.dp)) { Icon(Icons.prev, "Anterior", Modifier.size(34.dp), tint = Color.White) }
            IconButton(onClick = { activity.togglePlay() }, Modifier.size(76.dp)) {
                Icon(if (np.isPlaying) Icons.pause else Icons.play, "Reproducir", Modifier.size(52.dp), tint = Color.White)
            }
            IconButton(onClick = { activity.next() }, Modifier.size(64.dp)) { Icon(Icons.next, "Siguiente", Modifier.size(34.dp), tint = Color.White) }
        }
    }
}

// MARK: - Biblioteca

@Composable
private fun TopBar(title: String, onBack: () -> Unit, actions: @Composable RowScope.() -> Unit = {}) {
    Row(Modifier.fillMaxWidth().height(52.dp).padding(horizontal = 4.dp), verticalAlignment = Alignment.CenterVertically) {
        IconButton(onClick = onBack) { Icon(Icons.back, "Atrás", tint = Color.White) }
        Text(title, color = Color.White, fontSize = 17.sp, fontWeight = FontWeight.SemiBold, maxLines = 1,
            overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f))
        actions()
    }
    HorizontalDivider(color = Theme.line)
}

@Composable
private fun AlbumsScreen(activity: MainActivity, onBack: () -> Unit, onAlbum: (String) -> Unit, onPickFolder: () -> Unit) {
    val albums by Library.albums.collectAsState()
    val busy by Library.busy.collectAsState()
    val status by Library.status.collectAsState()
    var search by remember { mutableStateOf("") }
    var menu by remember { mutableStateOf(false) }
    val context = LocalContext.current
    val permission = if (Build.VERSION.SDK_INT >= 33) Manifest.permission.READ_MEDIA_AUDIO else Manifest.permission.READ_EXTERNAL_STORAGE
    val askPermission = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { ok ->
        if (ok) Library.refreshLocal() else Library.error.value = "Sin permiso no se puede leer la música del teléfono."
    }
    val phoneMusic = {
        if (ContextCompat.checkSelfPermission(context, permission) == PackageManager.PERMISSION_GRANTED) Library.refreshLocal()
        else askPermission.launch(permission)
    }
    val signedIn = remember(albums, busy) { OneDrive.isSignedIn }

    Column(Modifier.fillMaxSize()) {
        TopBar("Biblioteca", onBack) {
            Box {
                IconButton(onClick = { menu = true }, enabled = !busy) { Icon(Icons.add, "Agregar", tint = if (busy) Theme.dim else Color.White) }
                DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
                    if (signedIn) {
                        DropdownMenuItem(text = { Text("Carpeta OneDrive: ${OneDrive.folderName ?: "elegir"}") }, onClick = { menu = false; onPickFolder() })
                        DropdownMenuItem(text = { Text("Actualizar OneDrive") }, onClick = { menu = false; Library.refreshOneDrive() })
                        DropdownMenuItem(text = { Text("Cerrar sesión (${OneDrive.accountName ?: "OneDrive"})") }, onClick = { menu = false; Library.signOutOneDrive() })
                    } else {
                        DropdownMenuItem(text = { Text("Conectar OneDrive") }, onClick = { menu = false; activity.connectOneDrive() })
                    }
                    HorizontalDivider()
                    DropdownMenuItem(text = { Text("Música del teléfono") }, onClick = { menu = false; phoneMusic() })
                }
            }
        }

        if (albums.isEmpty() && !busy) {
            Column(Modifier.fillMaxSize().padding(32.dp), verticalArrangement = Arrangement.Center, horizontalAlignment = Alignment.CenterHorizontally) {
                Icon(Icons.note, null, Modifier.size(44.dp), tint = Theme.dim)
                Spacer(Modifier.height(14.dp))
                Text("Conecta tu música de OneDrive\no usa la música guardada en el teléfono", color = Theme.dim, textAlign = TextAlign.Center, fontSize = 14.sp)
                Spacer(Modifier.height(20.dp))
                Button(onClick = { if (signedIn) onPickFolder() else activity.connectOneDrive() }) { Text(if (signedIn) "Elegir carpeta de OneDrive" else "Conectar OneDrive") }
                Spacer(Modifier.height(8.dp))
                OutlinedButton(onClick = phoneMusic) { Text("Música del teléfono") }
            }
            return@Column
        }

        Row(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 10.dp)
            .background(Color.White.copy(alpha = 0.06f), RoundedCornerShape(10.dp)).padding(horizontal = 12.dp, vertical = 9.dp)) {
            BasicTextField(search, { search = it }, singleLine = true, textStyle = TextStyle(color = Color.White, fontSize = 14.sp),
                cursorBrush = SolidColor(Theme.accent), modifier = Modifier.fillMaxWidth(),
                decorationBox = { inner -> if (search.isEmpty()) Text("Buscar álbum o artista", color = Theme.dim, fontSize = 14.sp); inner() })
        }
        if (busy) {
            Row(Modifier.padding(horizontal = 16.dp, vertical = 6.dp), verticalAlignment = Alignment.CenterVertically) {
                CircularProgressIndicator(Modifier.size(16.dp), strokeWidth = 2.dp)
                Spacer(Modifier.width(10.dp))
                Text(status, color = Theme.dim, fontSize = 12.sp)
            }
        }
        val shown = if (search.isBlank()) albums else albums.filter {
            it.title.contains(search, true) || it.artist.contains(search, true)
        }
        LazyColumn(Modifier.fillMaxSize()) {
            items(shown, key = { it.key }) { a ->
                Row(Modifier.fillMaxWidth().clickable { onAlbum(a.key) }.padding(horizontal = 16.dp, vertical = 7.dp),
                    verticalAlignment = Alignment.CenterVertically) {
                    Thumb(a.key, 54)
                    Spacer(Modifier.width(12.dp))
                    Column(Modifier.weight(1f)) {
                        Text(a.title, color = Color.White, fontSize = 15.sp, fontWeight = FontWeight.Medium, maxLines = 1, overflow = TextOverflow.Ellipsis)
                        Text(listOfNotNull(a.artist, a.year).joinToString(" · "), color = Theme.dim, fontSize = 12.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
                    }
                    Badge(if (a.isOneDrive) "ONEDRIVE" else a.tracks.first().format.uppercase())
                }
            }
        }
    }
}

@Composable
private fun Badge(text: String) {
    Text(text, color = Theme.dim, fontSize = 9.sp, fontFamily = FontFamily.Monospace, fontWeight = FontWeight.SemiBold,
        modifier = Modifier.border(1.dp, Theme.dim.copy(alpha = 0.5f), RoundedCornerShape(3.dp)).padding(horizontal = 5.dp, vertical = 2.dp))
}

@Composable
private fun Thumb(key: String, sizeDp: Int) {
    val art = rememberArtwork(key)
    Box(Modifier.size(sizeDp.dp).clip(RoundedCornerShape(if (sizeDp > 100) 8.dp else 4.dp)).background(Theme.bar), contentAlignment = Alignment.Center) {
        if (art != null) Image(art, null, Modifier.fillMaxSize(), contentScale = ContentScale.Crop)
        else Icon(Icons.note, null, tint = Theme.dim, modifier = Modifier.size((sizeDp / 2.5).dp))
    }
}

@Composable
private fun AlbumScreen(activity: MainActivity, album: Album, onBack: () -> Unit, onPlay: () -> Unit) {
    val np by activity.nowPlaying
    Column(Modifier.fillMaxSize()) {
        TopBar(album.title, onBack)
        LazyColumn(Modifier.fillMaxSize()) {
            item {
                Column(Modifier.fillMaxWidth().padding(vertical = 16.dp), horizontalAlignment = Alignment.CenterHorizontally) {
                    Thumb(album.key, 210)
                    Spacer(Modifier.height(12.dp))
                    Text(album.title, color = Color.White, fontSize = 18.sp, fontWeight = FontWeight.SemiBold, textAlign = TextAlign.Center,
                        modifier = Modifier.padding(horizontal = 24.dp))
                    Text(album.artist, color = Theme.dim, fontSize = 14.sp)
                    Spacer(Modifier.height(2.dp))
                    Text(listOfNotNull(album.year, "${album.tracks.size} canciones",
                        album.totalMs.takeIf { it > 0 }?.let(::formatTime), if (album.isOneDrive) "OneDrive" else null).joinToString(" · "),
                        color = Theme.dim, fontSize = 11.sp)
                    Spacer(Modifier.height(12.dp))
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Button(onClick = { activity.play(album, 0); onPlay() }) {
                            Icon(Icons.play, null, Modifier.size(18.dp)); Spacer(Modifier.width(6.dp)); Text("Reproducir")
                        }
                        if (album.isOneDrive) {
                            Spacer(Modifier.width(14.dp))
                            DownloadButton(album)
                        }
                    }
                }
            }
            itemsIndexed(album.tracks, key = { _, t -> t.id }) { i, t ->
                val current = np.track?.uri == t.uri
                Row(Modifier.fillMaxWidth().clickable { activity.play(album, i); onPlay() }.padding(horizontal = 16.dp, vertical = 11.dp),
                    verticalAlignment = Alignment.CenterVertically) {
                    Box(Modifier.width(36.dp), contentAlignment = Alignment.CenterEnd) {
                        if (current) Icon(Icons.speaker, null, Modifier.size(16.dp), tint = Theme.accent)
                        else Text(if (album.multiDisc) "${t.disc}-%02d".format(t.trackNumber) else "%02d".format(t.trackNumber),
                            color = Theme.dim, fontSize = 13.sp)
                    }
                    Spacer(Modifier.width(14.dp))
                    Text(t.title, color = if (current) Theme.accent else Color.White, fontSize = 14.sp, maxLines = 1,
                        overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f))
                    if (t.durationMs > 0) Text(formatTime(t.durationMs), color = Theme.dim, fontSize = 13.sp)
                }
            }
            item { Spacer(Modifier.height(24.dp)) }
        }
    }
}

// MARK: - Descargar álbum al teléfono

@Composable
private fun DownloadButton(album: Album) {
    val offline by Library.offlineState.collectAsState()
    val downloads by Library.downloads.collectAsState()
    val progress = downloads[album.key]
    val saved = album.tracks.count { it.id in offline }
    val complete = saved == album.tracks.size
    var confirmRemove by remember { mutableStateOf(false) }

    Box(
        Modifier.size(52.dp).clip(RoundedCornerShape(10.dp)).background(Theme.bar)
            .clickable(enabled = progress == null) { if (complete) confirmRemove = true else Library.download(album) },
        contentAlignment = Alignment.Center,
    ) {
        if (progress != null) {
            CircularProgressIndicator(
                progress = { if (progress.second > 0) progress.first.toFloat() / progress.second else 0f },
                modifier = Modifier.size(40.dp), strokeWidth = 3.dp, color = Theme.accent, trackColor = Theme.line,
            )
            Text("${progress.first}/${progress.second}", color = Color.White, fontSize = 9.sp)
        } else {
            // La integral de Sonora + flecha (roja: descargar, verde: ya está en el teléfono)
            Image(painterResource(R.drawable.ic_launcher_foreground), null, Modifier.size(52.dp))
            Icon(
                if (complete) Icons.check else Icons.down, if (complete) "Descargado" else "Descargar",
                tint = if (complete) Color(0xFF5BD18B) else Color(0xFFE5484D),
                modifier = Modifier.align(Alignment.BottomEnd).padding(end = 3.dp, bottom = 3.dp).size(18.dp),
            )
        }
    }
    if (saved in 1 until album.tracks.size && progress == null) {
        Text("$saved/${album.tracks.size}", color = Theme.dim, fontSize = 10.sp, modifier = Modifier.padding(start = 6.dp))
    }

    if (confirmRemove) {
        AlertDialog(
            onDismissRequest = { confirmRemove = false },
            title = { Text("Álbum descargado") },
            text = { Text("Está guardado en Música/Sonora del teléfono y se escucha sin internet. ¿Quieres borrarlo del teléfono? Seguirá disponible desde OneDrive.") },
            confirmButton = { TextButton(onClick = { confirmRemove = false; Library.removeDownload(album) }) { Text("Borrar del teléfono") } },
            dismissButton = { TextButton(onClick = { confirmRemove = false }) { Text("Cancelar") } },
        )
    }
}

// MARK: - Elegir carpeta de OneDrive

@Composable
private fun FolderPicker(
    here: Pair<String?, String>,
    onBack: () -> Unit,
    onOpen: (String, String) -> Unit,
    onChoose: (String, String) -> Unit,
) {
    val (id, name) = here
    var items by remember(id) { mutableStateOf<List<DriveItem>?>(null) }
    var err by remember(id) { mutableStateOf<String?>(null) }
    LaunchedEffect(id) {
        try {
            items = withContext(Dispatchers.IO) { OneDrive.children(id) }.sortedBy { it.name.lowercase() }
        } catch (e: Exception) {
            err = e.message
        }
    }
    Column(Modifier.fillMaxSize()) {
        TopBar(name, onBack)
        Box(Modifier.weight(1f)) {
            when {
                err != null -> Text(err!!, color = Color(0xFFFF7A7A), modifier = Modifier.padding(16.dp))
                items == null -> CircularProgressIndicator(Modifier.align(Alignment.Center))
                else -> {
                    val folders = items!!.filter { it.isFolder }
                    val songs = items!!.count { it.name.substringAfterLast('.', "").lowercase() in AUDIO_EXTENSIONS }
                    LazyColumn {
                        if (folders.isEmpty()) item {
                            Text(if (songs > 0) "$songs canciones en esta carpeta" else "Sin subcarpetas", color = Theme.dim,
                                fontSize = 13.sp, modifier = Modifier.padding(16.dp))
                        }
                        items(folders, key = { it.id }) { f ->
                            Row(Modifier.fillMaxWidth().clickable { onOpen(f.id, f.name) }.padding(horizontal = 16.dp, vertical = 14.dp),
                                verticalAlignment = Alignment.CenterVertically) {
                                Icon(Icons.folder, null, tint = Theme.accent, modifier = Modifier.size(22.dp))
                                Spacer(Modifier.width(14.dp))
                                Text(f.name, color = Color.White, fontSize = 15.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
                            }
                        }
                    }
                }
            }
        }
        if (id != null) {
            Button(onClick = { onChoose(id, name) }, modifier = Modifier.fillMaxWidth().padding(16.dp)) {
                Text("Usar \"$name\" como biblioteca")
            }
        } else {
            Text("Entra a tu carpeta de música y elígela abajo", color = Theme.dim, fontSize = 12.sp,
                fontStyle = FontStyle.Italic, modifier = Modifier.padding(16.dp).align(Alignment.CenterHorizontally))
        }
    }
}
