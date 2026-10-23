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
        val cache = File(dir, md5(t.id) + ".json")
        if (cache.exists()) return runCatching { parse(JSONObject(cache.readText())) }.getOrNull()

        val artist = t.artist.takeIf { it != "Artista desconocido" } ?: ""
        val title = cleanForSearch(t.title, artist)
        val album = cleanForSearch(t.album)
        var found: JSONObject? = null

        val secs = (durationMs / 1000).toInt()
        if (artist.isNotBlank() && secs > 0) {
            val (code, body) = httpGet("https://lrclib.net/api/get?artist_name=${Uri.encode(artist)}&track_name=${Uri.encode(title)}" +
                "&album_name=${Uri.encode(album)}&duration=$secs")
            if (code == 200) found = runCatching { JSONObject(body) }.getOrNull()
        }
        if (found == null) {
            val q = buildString {
                append("track_name=").append(Uri.encode(title))
                if (artist.isNotBlank()) append("&artist_name=").append(Uri.encode(artist))
            }
            val (code, body) = httpGet("https://lrclib.net/api/search?$q")
            if (code == 200) {
                val arr = runCatching { JSONArray(body) }.getOrNull()
                if (arr != null && arr.length() > 0) {
                    val all = (0 until arr.length()).map { arr.getJSONObject(it) }
                    // Prefiere letra sincronizada y duración parecida
                    found = all.sortedWith(compareBy<JSONObject>(
                        { it.optString("syncedLyrics").isBlank() },
                        { if (secs > 0) kotlin.math.abs(it.optDouble("duration", 0.0) - secs) else 0.0 },
                    )).first()
                }
            } else if (code !in 400..499) return null   // error de red: no guardar en caché
        }
        val json = found ?: JSONObject().put("notFound", true)
        runCatching { cache.writeText(json.toString()) }
        return parse(json)
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
