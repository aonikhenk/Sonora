package cl.zanetta.sonora

import org.json.JSONArray
import org.json.JSONObject
import java.security.MessageDigest

data class Track(
    val id: String,            // "ms:<id>" (teléfono) u "od:<id>" (OneDrive)
    val uri: String,           // content://…  u  onedrive://item/<id>
    val title: String,
    val artist: String,
    val album: String,
    val albumKey: String,
    val trackNumber: Int,
    val disc: Int,
    val year: String?,
    val durationMs: Long,
    val format: String,
    val source: String,        // "local" | "onedrive"
) {
    val isOneDrive get() = source == SOURCE_ONEDRIVE

    fun toJson(): JSONObject = JSONObject()
        .put("id", id).put("uri", uri).put("title", title).put("artist", artist)
        .put("album", album).put("albumKey", albumKey).put("track", trackNumber)
        .put("disc", disc).put("year", year ?: "").put("dur", durationMs)
        .put("format", format).put("source", source)

    companion object {
        const val SOURCE_LOCAL = "local"
        const val SOURCE_ONEDRIVE = "onedrive"

        fun fromJson(o: JSONObject) = Track(
            id = o.getString("id"), uri = o.getString("uri"), title = o.getString("title"),
            artist = o.getString("artist"), album = o.getString("album"),
            albumKey = o.getString("albumKey"), trackNumber = o.optInt("track"),
            disc = o.optInt("disc", 1), year = o.optString("year").ifEmpty { null },
            durationMs = o.optLong("dur"), format = o.optString("format"),
            source = o.getString("source"),
        )

        fun listToJson(list: List<Track>) = JSONArray().apply { list.forEach { put(it.toJson()) } }.toString()
        fun listFromJson(s: String): List<Track> {
            val a = JSONArray(s)
            return (0 until a.length()).map { fromJson(a.getJSONObject(it)) }
        }
    }
}

data class Album(val key: String, val tracks: List<Track>) {
    val title get() = tracks.first().album
    val artist get() = tracks.first().artist
    val year get() = tracks.firstNotNullOfOrNull { it.year }
    val isOneDrive get() = tracks.first().isOneDrive
    val totalMs get() = tracks.sumOf { it.durationMs }
    val multiDisc get() = tracks.map { it.disc }.toSet().size > 1
}

fun formatTime(ms: Long): String {
    val t = (ms.coerceAtLeast(0) / 1000).toInt()
    return if (t >= 3600) "%d:%02d:%02d".format(t / 3600, (t / 60) % 60, t % 60)
    else "%d:%02d".format(t / 60, t % 60)
}

fun md5(s: String): String =
    MessageDigest.getInstance("MD5").digest(s.toByteArray()).joinToString("") { "%02x".format(it) }

val AUDIO_EXTENSIONS = setOf("flac", "wav", "wave", "aif", "aiff", "m4a", "alac", "mp3", "aac", "ogg", "opus")

/** "01 - Canción" → (1, "Canción") */
fun parseFileName(name: String): Pair<Int, String> {
    val base = name.substringBeforeLast('.')
    val digits = base.takeWhile { it.isDigit() }
    val title = base.drop(digits.length).trim(' ', '.', '-', '_', ')').ifEmpty { base }
    return (digits.toIntOrNull() ?: 0) to title
}
