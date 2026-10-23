package cl.zanetta.sonora

import android.content.ContentUris
import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.os.Build
import android.provider.MediaStore
import android.util.LruCache
import android.util.Size
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File
import java.net.URL

object Library {
    private lateinit var app: Context
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)

    private val _albums = MutableStateFlow<List<Album>>(emptyList())
    val albums: StateFlow<List<Album>> = _albums
    val busy = MutableStateFlow(false)
    val status = MutableStateFlow("")
    val error = MutableStateFlow<String?>(null)

    private var local: List<Track> = emptyList()
    private var oneDrive: List<Track> = emptyList()

    private val storeFile get() = File(app.filesDir, "onedrive.json")
    val artDir get() = File(app.filesDir, "art").apply { mkdirs() }

    fun init(context: Context) {
        app = context.applicationContext
        oneDrive = runCatching { Track.listFromJson(storeFile.readText()) }.getOrDefault(emptyList())
        offline = runCatching {
            val o = org.json.JSONObject(offlineFile.readText())
            o.keys().asSequence().associateWith { o.getString(it) }
        }.getOrDefault(emptyMap())
        _offlineState.value = offline.keys
        rebuild()
        refreshLocal()
    }

    fun track(id: String): Track? = (local + oneDrive).firstOrNull { it.id == id }

    // MARK: Música del teléfono (MediaStore)

    fun refreshLocal() {
        scope.launch {
            local = withContext(Dispatchers.IO) { runCatching { queryMediaStore() }.getOrDefault(emptyList()) }
            // Las canciones descargadas desde OneDrive no se muestran dos veces
            val downloadedIds = offline.values.map { "ms:" + android.net.Uri.parse(it).lastPathSegment }.toSet()
            local = local.filter { it.id !in downloadedIds }
            rebuild()
        }
    }

    private fun queryMediaStore(): List<Track> {
        val uri = MediaStore.Audio.Media.EXTERNAL_CONTENT_URI
        val proj = arrayOf(
            MediaStore.Audio.Media._ID, MediaStore.Audio.Media.TITLE, MediaStore.Audio.Media.ARTIST,
            MediaStore.Audio.Media.ALBUM, MediaStore.Audio.Media.ALBUM_ID, MediaStore.Audio.Media.TRACK,
            MediaStore.Audio.Media.YEAR, MediaStore.Audio.Media.DURATION, MediaStore.Audio.Media.DISPLAY_NAME,
            "album_artist",
        )
        val out = mutableListOf<Track>()
        app.contentResolver.query(uri, proj, "${MediaStore.Audio.Media.IS_MUSIC} != 0", null, null)?.use { c ->
            while (c.moveToNext()) {
                val id = c.getLong(0)
                val name = c.getString(8) ?: ""
                val (num, fileTitle) = parseFileName(name)
                val trackField = c.getInt(5)
                val albumArtist = c.getString(9)?.takeIf { it.isNotBlank() && it != "<unknown>" }
                val artist = albumArtist ?: c.getString(2)?.takeIf { it != "<unknown>" } ?: "Artista desconocido"
                out += Track(
                    id = "ms:$id",
                    uri = ContentUris.withAppendedId(uri, id).toString(),
                    title = c.getString(1)?.ifBlank { null } ?: fileTitle,
                    artist = artist,
                    album = c.getString(3) ?: "Sin álbum",
                    albumKey = "ms:" + c.getLong(4),
                    trackNumber = if (trackField > 0) trackField % 1000 else num,
                    disc = if (trackField >= 1000) trackField / 1000 else 1,
                    year = c.getInt(6).takeIf { it > 0 }?.toString(),
                    durationMs = c.getLong(7),
                    format = name.substringAfterLast('.', "").lowercase(),
                    source = Track.SOURCE_LOCAL,
                )
            }
        }
        return out
    }

    // MARK: OneDrive

    fun useOneDriveFolder(id: String, name: String) {
        OneDrive.folderId = id
        OneDrive.folderName = name
        oneDrive = emptyList()
        save()
        rebuild()
        refreshOneDrive()
    }

    // MARK: Descargas para escuchar sin internet (OneDrive → carpeta Música/Sonora del teléfono)

    private var offline: Map<String, String> = emptyMap()          // id de canción OneDrive → content:// local
    private val offlineFile get() = File(app.filesDir, "offline.json")
    private val _offlineState = MutableStateFlow<Set<String>>(emptySet())
    val offlineState: StateFlow<Set<String>> = _offlineState
    /** Progreso de descarga por álbum: (listas, total). */
    val downloads = MutableStateFlow<Map<String, Pair<Int, Int>>>(emptyMap())

    /** Uri que se reproduce: la copia del teléfono si existe, si no OneDrive. */
    fun playableUri(t: Track): String = offline[t.id] ?: t.uri

    fun trackForPlayable(uri: String): Track? {
        val id = offline.entries.firstOrNull { it.value == uri }?.key
        return _albums.value.asSequence().flatMap { it.tracks }.firstOrNull { it.uri == uri || it.id == id }
    }

    fun offlineCount(album: Album) = album.tracks.count { it.id in _offlineState.value }

    private fun saveOffline() {
        runCatching { offlineFile.writeText(org.json.JSONObject(offline).toString()) }
        _offlineState.value = offline.keys
    }

    fun download(album: Album) {
        if (downloads.value.containsKey(album.key)) return
        val todo = album.tracks.filter { it.isOneDrive && it.id !in offline }
        if (todo.isEmpty()) return
        downloads.value = downloads.value + (album.key to (0 to todo.size))
        scope.launch {
            var done = 0
            var failed = 0
            for (t in todo) {
                val uri = withContext(Dispatchers.IO) { runCatching { saveToPhone(t) }.getOrNull() }
                if (uri != null) {
                    offline = offline + (t.id to uri)
                    saveOffline()
                } else failed++
                done++
                downloads.value = downloads.value + (album.key to (done to todo.size))
            }
            downloads.value = downloads.value - album.key
            if (failed > 0) error.value = "No se pudieron descargar $failed canciones. Revisa la conexión e inténtalo de nuevo."
        }
    }

    fun removeDownload(album: Album) {
        scope.launch {
            withContext(Dispatchers.IO) {
                for (t in album.tracks) offline[t.id]?.let { u ->
                    runCatching {
                        val uri = android.net.Uri.parse(u)
                        if (uri.scheme == "file") File(uri.path!!).delete() else app.contentResolver.delete(uri, null, null)
                    }
                }
            }
            offline = offline - album.tracks.map { it.id }.toSet()
            saveOffline()
        }
    }

    private fun saveToPhone(t: Track): String {
        val url = OneDrive.downloadUrl(t.id.removePrefix("od:"))
        val safe = { s: String -> s.replace(Regex("[\\\\/:*?\"<>|]"), "_").trim().ifEmpty { "Sonora" } }
        val name = "%02d - %s.%s".format(t.trackNumber, safe(t.title), t.format)
        val mime = when (t.format) {
            "flac" -> "audio/flac"; "mp3" -> "audio/mpeg"; "wav", "wave" -> "audio/wav"
            "m4a", "alac", "aac" -> "audio/mp4"; "aif", "aiff" -> "audio/aiff"; "ogg", "opus" -> "audio/ogg"
            else -> "audio/*"
        }
        if (Build.VERSION.SDK_INT >= 29) {
            val resolver = app.contentResolver
            val values = android.content.ContentValues().apply {
                put(MediaStore.Audio.Media.DISPLAY_NAME, name)
                put(MediaStore.Audio.Media.MIME_TYPE, mime)
                put(MediaStore.Audio.Media.RELATIVE_PATH, "Music/Sonora/${safe(t.artist)}/${safe(t.album)}")
                put(MediaStore.Audio.Media.IS_PENDING, 1)
            }
            val uri = resolver.insert(MediaStore.Audio.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY), values)
                ?: throw OneDriveException("No se pudo crear el archivo")
            try {
                URL(url).openStream().use { input -> resolver.openOutputStream(uri)!!.use { input.copyTo(it, 256 * 1024) } }
                values.clear()
                values.put(MediaStore.Audio.Media.IS_PENDING, 0)
                resolver.update(uri, values, null, null)
                return uri.toString()
            } catch (e: Exception) {
                resolver.delete(uri, null, null)
                throw e
            }
        } else {
            val dir = File(app.getExternalFilesDir(android.os.Environment.DIRECTORY_MUSIC), "${safe(t.artist)}/${safe(t.album)}").apply { mkdirs() }
            val f = File(dir, name)
            URL(url).openStream().use { input -> f.outputStream().use { input.copyTo(it, 256 * 1024) } }
            return android.net.Uri.fromFile(f).toString()
        }
    }

    fun signOutOneDrive() {
        OneDrive.signOut()
        oneDrive = emptyList()
        save()
        rebuild()
        Media.clearCache(app)
    }

    fun refreshOneDrive() {
        val root = OneDrive.folderId ?: return
        if (!OneDrive.isSignedIn || busy.value) return
        busy.value = true
        status.value = "Leyendo OneDrive…"
        scope.launch {
            try {
                val found = mutableListOf<Track>()
                val covers = mutableMapOf<String, String>()
                withContext(Dispatchers.IO) {
                    val pending = ArrayDeque(listOf(root to emptyList<String>()))
                    var folders = 0
                    while (pending.isNotEmpty()) {
                        val (folderId, path) = pending.removeFirst()
                        val items = OneDrive.children(folderId)
                        folders++
                        status.value = "Leyendo OneDrive… $folders carpetas, ${found.size} canciones"
                        val key = "od:$folderId"
                        var cover: String? = null
                        var thumb: String? = null
                        for (item in items) {
                            if (item.isFolder) { pending.add(item.id to path + item.name); continue }
                            val ext = item.name.substringAfterLast('.', "").lowercase()
                            if (ext in setOf("jpg", "jpeg", "png")) {
                                val base = item.name.substringBeforeLast('.').lowercase()
                                if (cover == null || base in setOf("cover", "folder", "front")) cover = item.downloadUrl
                                continue
                            }
                            if (ext !in AUDIO_EXTENSIONS) continue
                            found += trackFrom(item, ext, path, key)
                            if (thumb == null) thumb = item.thumbnail
                        }
                        (cover ?: thumb)?.let { if (!artFile(key).exists()) covers[key] = it }
                    }
                }
                oneDrive = found
                save()
                rebuild()
                var i = 0
                withContext(Dispatchers.IO) {
                    for ((key, url) in covers) {
                        i++
                        status.value = "Carátulas $i de ${covers.size}…"
                        runCatching { URL(url).openStream().use { s -> artFile(key).outputStream().use { s.copyTo(it) } } }
                    }
                }
                rebuild()
            } catch (e: Exception) {
                error.value = e.message ?: "Error leyendo OneDrive"
            }
            busy.value = false
            status.value = ""
        }
    }

    private fun trackFrom(item: DriveItem, ext: String, path: List<String>, key: String): Track {
        val (num, fileTitle) = parseFileName(item.name)
        var album = path.lastOrNull() ?: (OneDrive.folderName ?: "OneDrive")
        var artist = if (path.size >= 2) path[path.size - 2] else "Artista desconocido"
        if (path.size < 2 && album.contains(" - ")) {
            artist = album.substringBefore(" - ")
            album = album.substringAfter(" - ")
        }
        val a = item.audio
        fun s(k: String) = a?.optString(k)?.ifBlank { null }
        return Track(
            id = "od:${item.id}",
            uri = OneDrive.itemUri(item.id),
            title = s("title") ?: fileTitle,
            artist = s("albumArtist") ?: s("artist") ?: artist,
            album = s("album") ?: album,
            albumKey = key,
            trackNumber = a?.optInt("track")?.takeIf { it > 0 } ?: num,
            disc = a?.optInt("disc")?.takeIf { it > 0 } ?: 1,
            year = a?.optInt("year")?.takeIf { it > 0 }?.toString(),
            durationMs = a?.optLong("duration") ?: 0,
            format = ext,
            source = Track.SOURCE_ONEDRIVE,
        )
    }

    // MARK: Interno

    private fun rebuild() {
        _albums.value = (local + oneDrive)
            .groupBy { it.albumKey }
            .map { (k, ts) -> Album(k, ts.sortedWith(compareBy({ it.disc }, { it.trackNumber }, { it.title }))) }
            .sortedWith(compareBy({ it.artist.lowercase() }, { it.title.lowercase() }))
    }

    private fun save() {
        runCatching { storeFile.writeText(Track.listToJson(oneDrive)) }
    }

    // MARK: Carátulas

    private val memory = object : LruCache<String, Bitmap>(40 * 1024 * 1024) {
        override fun sizeOf(key: String, value: Bitmap) = value.byteCount
    }

    fun artFile(key: String) = File(artDir, md5(key) + ".jpg")

    /** Carátula del álbum (bloqueante, usar en Dispatchers.IO). */
    fun artwork(album: Album): Bitmap? {
        memory.get(album.key)?.let { return it }
        val f = artFile(album.key)
        if (!f.exists() && !album.isOneDrive && Build.VERSION.SDK_INT >= 29) {
            runCatching {
                val uri = android.net.Uri.parse(album.tracks.first().uri)
                val bmp = app.contentResolver.loadThumbnail(uri, Size(800, 800), null)
                f.outputStream().use { bmp.compress(Bitmap.CompressFormat.JPEG, 90, it) }
            }
        }
        if (!f.exists()) return null
        val opts = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeFile(f.path, opts)
        var sample = 1
        while (opts.outWidth / (sample * 2) >= 900) sample *= 2
        val bmp = BitmapFactory.decodeFile(f.path, BitmapFactory.Options().apply { inSampleSize = sample }) ?: return null
        memory.put(album.key, bmp)
        return bmp
    }

    fun album(key: String) = _albums.value.firstOrNull { it.key == key }
}
