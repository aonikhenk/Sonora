package cl.zanetta.sonora

import android.net.Uri
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.net.HttpURLConnection
import java.net.URL

private const val USER_AGENT = "Sonora/0.3 +https://github.com/aonikhenk/Sonora"

private fun httpGet(url: String, headers: Map<String, String> = emptyMap()): Pair<Int, String> {
    val c = URL(url).openConnection() as HttpURLConnection
    c.connectTimeout = 15000
    c.readTimeout = 20000
    c.setRequestProperty("User-Agent", USER_AGENT)
    headers.forEach { (k, v) -> c.setRequestProperty(k, v) }
    val code = c.responseCode
    val text = (if (code in 200..299) c.inputStream else c.errorStream)?.bufferedReader()?.readText() ?: ""
    return code to text
}

/** Quita agregados que entorpecen la búsqueda: "(Remastered 2008)", "[Deluxe]", "Artista - " al inicio… */
fun cleanForSearch(s: String, artist: String? = null): String {
    var t = s
    if (artist != null && t.startsWith("$artist - ", ignoreCase = true)) t = t.substring(artist.length + 3)
    t = t.replace(Regex("""\s*[\(\[][^)\]]*(remaster|deluxe|edition|version|bonus|live|mono|stereo|explicit)[^)\]]*[\)\]]""", RegexOption.IGNORE_CASE), "")
    return t.trim()
}

// MARK: - Carátulas desde Discogs (requiere token personal)

object Discogs {
    private val token get() = BuildConfig.DISCOGS_TOKEN
    val isConfigured get() = token.isNotBlank()

    /** URL de la portada en alta resolución para el álbum, o null (bloqueante). */
    fun coverUrl(artist: String, album: String): String? {
        val auth = mapOf("Authorization" to "Discogs token=$token")
        val title = cleanForSearch(album)
        val knownArtist = artist.takeIf { it.isNotBlank() && it != "Artista desconocido" }
        val queries = buildList {
            if (knownArtist != null) {
                add("type=release&artist=${Uri.encode(knownArtist)}&release_title=${Uri.encode(title)}")
                add("type=master&artist=${Uri.encode(knownArtist)}&release_title=${Uri.encode(title)}")
            }
            add("type=release&q=${Uri.encode(listOfNotNull(knownArtist, title).joinToString(" "))}")
        }
        for (q in queries) {
            val (code, body) = httpGet("https://api.discogs.com/database/search?$q&per_page=5", auth)
            if (code == 401) throw OneDriveException("El token de Discogs no es válido.")
            if (code == 429) { Thread.sleep(5000); continue }
            if (code !in 200..299) continue
            val results = runCatching { JSONObject(body).getJSONArray("results") }.getOrNull() ?: continue
            for (i in 0 until results.length()) {
                val img = results.getJSONObject(i).optString("cover_image")
                if (img.isNotBlank() && !img.endsWith("spacer.gif")) return img
            }
        }
        return null
    }

    fun download(url: String, dest: File): Boolean = runCatching {
        val c = URL(url).openConnection() as HttpURLConnection
        c.setRequestProperty("User-Agent", USER_AGENT)
        c.connectTimeout = 15000
        c.readTimeout = 30000
        if (c.responseCode !in 200..299) return false
        val tmp = File(dest.path + ".part")
        c.inputStream.use { input -> tmp.outputStream().use { input.copyTo(it) } }
        tmp.renameTo(dest)
    }.getOrDefault(false)
}

// MARK: - Letras sincronizadas desde LRCLIB (gratuito, sin clave)

data class LyricLine(val timeMs: Long, val text: String)
data class LyricsResult(val synced: List<LyricLine>?, val plain: String?, val instrumental: Boolean = false) {
    val isEmpty get() = synced.isNullOrEmpty() && plain.isNullOrBlank() && !instrumental
}

object Lyrics {
    private lateinit var dir: File

    fun init(cacheRoot: File) {
        dir = File(cacheRoot, "lyrics").apply { mkdirs() }
    }

    /** Busca la letra (primero en caché). Bloqueante; usar en Dispatchers.IO. */
    fun fetch(t: Track, durationMs: Long): LyricsResult? {
        val cache = File(dir, "v2-" + md5(t.id) + ".json")
        if (cache.exists()) {
            val o = runCatching { JSONObject(cache.readText()) }.getOrNull()
            // Si antes no se encontró, se vuelve a intentar después de 3 días
            val stale = o?.optBoolean("notFound") == true && System.currentTimeMillis() - o.optLong("at") > 3L * 86_400_000
            if (o != null && !stale) return parse(o)
        }

        val secs = (durationMs / 1000).toInt()
        val found = search(t, secs) ?: run {
            if (lastNetworkError) return null   // sin conexión: no guardar como "no encontrada"
            JSONObject().put("notFound", true).put("at", System.currentTimeMillis())
        }
        runCatching { cache.writeText(found.toString()) }
        return parse(found)
    }

    private var lastNetworkError = false

    /** Posibles (artista, canción): "Jeff Buckley - Hallelujah" en el título, o el artista de la etiqueta/carpeta. */
    private fun candidates(t: Track): List<Pair<String, String>> {
        val out = mutableListOf<Pair<String, String>>()
        val title = cleanForSearch(t.title)
        val parts = title.split(" - ").map { it.trim() }.filter { it.isNotEmpty() }
        if (parts.size >= 2) out += parts[0] to parts.drop(1).joinToString(" - ")
        val artist = t.artist.takeIf { it.isNotBlank() && it != "Artista desconocido" }
        if (artist != null) out += artist to cleanForSearch(t.title, artist)
        return out.distinct()
    }

    private fun search(t: Track, secs: Int): JSONObject? {
        lastNetworkError = false
        val pairs = candidates(t)
        val results = mutableListOf<JSONObject>()
        fun query(q: String) {
            val r = runCatching { httpGet("https://lrclib.net/api/search?$q") }.getOrElse { lastNetworkError = true; return }
            if (r.first != 200) { if (r.first >= 500) lastNetworkError = true; return }
            val arr = runCatching { JSONArray(r.second) }.getOrNull() ?: return
            for (i in 0 until arr.length()) results += arr.getJSONObject(i)
        }
        for ((artist, title) in pairs) {
            query("track_name=${Uri.encode(title)}&artist_name=${Uri.encode(artist)}")
            if (results.any { it.optString("syncedLyrics").isNotBlank() }) break
        }
        if (results.isEmpty()) query("q=${Uri.encode(pairs.firstOrNull()?.let { "${it.first} ${it.second}" } ?: cleanForSearch(t.title))}")
        if (results.isEmpty()) return null
        if (results.isNotEmpty()) lastNetworkError = false
        // Prefiere letra sincronizada y duración parecida a la canción
        return results.sortedWith(compareBy<JSONObject>(
            { it.optString("syncedLyrics").isBlank() || it.optString("syncedLyrics") == "null" },
            { if (secs > 0) kotlin.math.abs(it.optDouble("duration", 0.0) - secs) else 0.0 },
        )).first()
    }

    private fun parse(o: JSONObject): LyricsResult? {
        if (o.optBoolean("notFound")) return null
        val synced = o.optString("syncedLyrics").takeIf { it.isNotBlank() && it != "null" }?.let(::parseLrc)
        val plain = o.optString("plainLyrics").takeIf { it.isNotBlank() && it != "null" }
        return LyricsResult(synced, plain, o.optBoolean("instrumental"))
    }

    fun parseLrc(lrc: String): List<LyricLine> {
        val tag = Regex("""\[(\d+):(\d+(?:[.:]\d+)?)]""")
        val out = mutableListOf<LyricLine>()
        for (raw in lrc.lines()) {
            val tags = tag.findAll(raw).toList()
            if (tags.isEmpty()) continue
            val text = raw.substring(tags.last().range.last + 1).trim()
            for (m in tags) {
                val min = m.groupValues[1].toLong()
                val sec = m.groupValues[2].replace(':', '.').toDouble()
                out += LyricLine(min * 60_000 + (sec * 1000).toLong(), text)
            }
        }
        return out.sortedBy { it.timeMs }
    }
}
