package cl.zanetta.sonora

import android.content.Context
import android.content.SharedPreferences
import android.net.Uri
import android.util.Base64
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL
import java.net.URLEncoder
import java.security.MessageDigest
import java.security.SecureRandom

data class DriveItem(
    val id: String,
    val parentId: String? = null,
    val name: String,
    val isFolder: Boolean,
    val downloadUrl: String?,
    val thumbnail: String?,
    val audio: JSONObject?,
)

class OneDriveException(msg: String) : Exception(msg)

/**
 * Inicio de sesión de Microsoft (OAuth 2.0 + PKCE, sin secreto) y acceso a OneDrive por Microsoft Graph.
 * Las funciones de red son bloqueantes: llamarlas desde Dispatchers.IO o desde hilos de ExoPlayer.
 */
object OneDrive {
    private val clientId get() = BuildConfig.ONEDRIVE_CLIENT_ID
    private const val REDIRECT = "sonora://auth"
    private const val SCOPES = "Files.Read offline_access User.Read"
    private const val AUTHORITY = "https://login.microsoftonline.com/common/oauth2/v2.0"
    private const val GRAPH = "https://graph.microsoft.com/v1.0"

    private lateinit var prefs: SharedPreferences
    private var accessToken: String? = null
    private var expiresAt = 0L

    fun init(context: Context) {
        prefs = context.getSharedPreferences("onedrive", Context.MODE_PRIVATE)
    }

    val isConfigured get() = clientId.isNotBlank()
    val isSignedIn get() = prefs.getString("refresh", null) != null
    val accountName: String? get() = prefs.getString("account", null)

    var folderId: String?
        get() = prefs.getString("folderId", null)
        set(v) = prefs.edit().putString("folderId", v).apply()
    var folderName: String?
        get() = prefs.getString("folderName", null)
        set(v) = prefs.edit().putString("folderName", v).apply()

    // MARK: Inicio de sesión

    fun authorizeUri(): Uri {
        val verifier = random(64)
        val state = random(24)
        prefs.edit().putString("verifier", verifier).putString("state", state).apply()
        val challenge = b64(MessageDigest.getInstance("SHA-256").digest(verifier.toByteArray()))
        return Uri.parse("$AUTHORITY/authorize").buildUpon()
            .appendQueryParameter("client_id", clientId)
            .appendQueryParameter("response_type", "code")
            .appendQueryParameter("redirect_uri", REDIRECT)
            .appendQueryParameter("response_mode", "query")
            .appendQueryParameter("scope", SCOPES)
            .appendQueryParameter("state", state)
            .appendQueryParameter("code_challenge", challenge)
            .appendQueryParameter("code_challenge_method", "S256")
            .appendQueryParameter("prompt", "select_account")
            .build()
    }

    /** Procesa sonora://auth?code=… (bloqueante). */
    fun handleRedirect(uri: Uri) {
        uri.getQueryParameter("error_description")?.let { throw OneDriveException(it) }
        uri.getQueryParameter("error")?.let { throw OneDriveException(it) }
        if (uri.getQueryParameter("state") != prefs.getString("state", null)) throw OneDriveException("Respuesta inválida, intenta de nuevo.")
        val code = uri.getQueryParameter("code") ?: throw OneDriveException("Inicio de sesión cancelado.")
        requestToken(mapOf(
            "grant_type" to "authorization_code",
            "code" to code,
            "redirect_uri" to REDIRECT,
            "code_verifier" to (prefs.getString("verifier", "") ?: ""),
        ))
        runCatching {
            val me = getJson("$GRAPH/me")
            prefs.edit().putString("account", me.optString("userPrincipalName").ifEmpty { me.optString("displayName") }).apply()
        }
    }

    // MARK: Inicio de sesión con código (TV): se confirma desde el teléfono o el PC

    data class DeviceCode(val userCode: String, val verificationUri: String, val deviceCode: String, val intervalSec: Int, val expiresAt: Long)

    /** Pide un código para que el usuario inicie sesión en microsoft.com/devicelogin (bloqueante). */
    fun startDeviceLogin(): DeviceCode {
        val json = postForm("$AUTHORITY/devicecode", mapOf("client_id" to clientId, "scope" to SCOPES))
        if (!json.has("device_code")) throw OneDriveException(json.optString("error_description").ifEmpty { "No se pudo obtener el código" })
        return DeviceCode(
            userCode = json.getString("user_code"),
            verificationUri = json.optString("verification_uri").ifEmpty { "https://microsoft.com/devicelogin" },
            deviceCode = json.getString("device_code"),
            intervalSec = json.optInt("interval", 5),
            expiresAt = System.currentTimeMillis() + json.optLong("expires_in", 900) * 1000,
        )
    }

    /** Consulta una vez si el usuario ya aprobó el código. true = sesión iniciada; false = aún pendiente. */
    fun pollDeviceLogin(code: DeviceCode): Boolean {
        val json = postForm("$AUTHORITY/token", mapOf(
            "grant_type" to "urn:ietf:params:oauth:grant-type:device_code",
            "client_id" to clientId,
            "device_code" to code.deviceCode,
        ))
        if (json.has("access_token")) {
            accessToken = json.getString("access_token")
            expiresAt = System.currentTimeMillis() + (json.optLong("expires_in", 3600) - 120) * 1000
            json.optString("refresh_token").takeIf { it.isNotEmpty() }?.let { prefs.edit().putString("refresh", it).apply() }
            runCatching {
                val me = getJson("$GRAPH/me")
                prefs.edit().putString("account", me.optString("userPrincipalName").ifEmpty { me.optString("displayName") }).apply()
            }
            return true
        }
        return when (json.optString("error")) {
            "authorization_pending", "slow_down" -> false
            "expired_token" -> throw OneDriveException("El código expiró. Vuelve a intentarlo.")
            "authorization_declined" -> throw OneDriveException("Se canceló el inicio de sesión.")
            else -> throw OneDriveException(json.optString("error_description").ifEmpty { "Error de inicio de sesión" })
        }
    }

    private fun postForm(url: String, params: Map<String, String>): JSONObject {
        val body = params.entries.joinToString("&") { "${it.key}=${URLEncoder.encode(it.value, "UTF-8")}" }
        val c = URL(url).openConnection() as HttpURLConnection
        c.requestMethod = "POST"
        c.doOutput = true
        c.setRequestProperty("Content-Type", "application/x-www-form-urlencoded")
        c.outputStream.use { it.write(body.toByteArray()) }
        val code = c.responseCode
        val text = (if (code in 200..299) c.inputStream else c.errorStream)?.bufferedReader()?.readText() ?: "{}"
        return runCatching { JSONObject(text) }.getOrDefault(JSONObject())
    }

    fun signOut() {
        prefs.edit().clear().apply()
        accessToken = null
        expiresAt = 0
    }

    @Synchronized
    private fun requestToken(params: Map<String, String>) {
        val all = params + mapOf("client_id" to clientId, "scope" to SCOPES)
        val body = all.entries.joinToString("&") { "${it.key}=${URLEncoder.encode(it.value, "UTF-8")}" }
        val c = URL("$AUTHORITY/token").openConnection() as HttpURLConnection
        c.requestMethod = "POST"
        c.doOutput = true
        c.setRequestProperty("Content-Type", "application/x-www-form-urlencoded")
        c.outputStream.use { it.write(body.toByteArray()) }
        val code = c.responseCode
        val text = (if (code in 200..299) c.inputStream else c.errorStream)?.bufferedReader()?.readText() ?: ""
        val json = runCatching { JSONObject(text) }.getOrNull()
        if (code != 200 || json == null || !json.has("access_token")) {
            val msg = json?.optString("error_description")?.ifEmpty { null } ?: "Error de autenticación ($code)"
            if (code == 400 && params["grant_type"] == "refresh_token") signOut()
            throw OneDriveException(msg)
        }
        accessToken = json.getString("access_token")
        expiresAt = System.currentTimeMillis() + (json.optLong("expires_in", 3600) - 120) * 1000
        json.optString("refresh_token").takeIf { it.isNotEmpty() }?.let { prefs.edit().putString("refresh", it).apply() }
    }

    @Synchronized
    private fun token(): String {
        accessToken?.let { if (System.currentTimeMillis() < expiresAt) return it }
        val refresh = prefs.getString("refresh", null) ?: throw OneDriveException("Inicia sesión en OneDrive.")
        requestToken(mapOf("grant_type" to "refresh_token", "refresh_token" to refresh))
        return accessToken!!
    }

    // MARK: Microsoft Graph

    private fun getJson(url: String): JSONObject {
        val c = URL(url).openConnection() as HttpURLConnection
        c.setRequestProperty("Authorization", "Bearer ${token()}")
        c.connectTimeout = 15000
        c.readTimeout = 30000
        val code = c.responseCode
        val text = (if (code in 200..299) c.inputStream else c.errorStream)?.bufferedReader()?.readText() ?: ""
        if (code !in 200..299) throw OneDriveException("OneDrive respondió $code")
        return JSONObject(text)
    }

    fun children(folderId: String?): List<DriveItem> {
        var next: String? = (if (folderId == null) "$GRAPH/me/drive/root/children" else "$GRAPH/me/drive/items/${Uri.encode(folderId)}/children") +
            "?\$top=200&\$expand=thumbnails"
        val out = mutableListOf<DriveItem>()
        while (next != null) {
            val page = getJson(next)
            val arr = page.getJSONArray("value")
            for (i in 0 until arr.length()) {
                val o = arr.getJSONObject(i)
                val thumbs = o.optJSONArray("thumbnails")?.optJSONObject(0)
                out += DriveItem(
                    id = o.getString("id"),
                    name = o.getString("name"),
                    isFolder = o.has("folder"),
                    downloadUrl = o.optString("@microsoft.graph.downloadUrl").ifEmpty { null },
                    thumbnail = (thumbs?.optJSONObject("large") ?: thumbs?.optJSONObject("medium"))?.optString("url")?.ifEmpty { null },
                    audio = o.optJSONObject("audio"),
                )
            }
            next = page.optString("@odata.nextLink").ifEmpty { null }
        }
        return out
    }

    /**
     * Todo el contenido de una carpeta y sus subcarpetas en pocas consultas (API "delta").
     * Mucho más rápido que recorrer carpeta por carpeta.
     */
    fun deltaTree(folderId: String, onPage: (Int) -> Unit): List<DriveItem> {
        var next: String? = "$GRAPH/me/drive/items/${Uri.encode(folderId)}/delta"
        val out = mutableListOf<DriveItem>()
        while (next != null) {
            val page = getJson(next)
            val arr = page.getJSONArray("value")
            for (i in 0 until arr.length()) {
                val o = arr.getJSONObject(i)
                if (o.has("deleted")) continue
                out += DriveItem(
                    id = o.getString("id"),
                    parentId = o.optJSONObject("parentReference")?.optString("id")?.ifEmpty { null },
                    name = o.optString("name"),
                    isFolder = o.has("folder"),
                    downloadUrl = o.optString("@microsoft.graph.downloadUrl").ifEmpty { null },
                    thumbnail = null,
                    audio = o.optJSONObject("audio"),
                )
            }
            onPage(out.size)
            next = page.optString("@odata.nextLink").ifEmpty { null }
        }
        return out
    }

    /** Miniatura grande (carátula incrustada) de un archivo, si OneDrive la tiene. */
    fun thumbnailUrl(itemId: String): String? = runCatching {
        val set = getJson("$GRAPH/me/drive/items/${Uri.encode(itemId)}/thumbnails").getJSONArray("value").optJSONObject(0)
        (set?.optJSONObject("large") ?: set?.optJSONObject("medium"))?.optString("url")?.ifEmpty { null }
    }.getOrNull()

    /** Enlace directo de descarga (válido ~1 hora). */
    fun downloadUrl(itemId: String): String =
        getJson("$GRAPH/me/drive/items/${Uri.encode(itemId)}").optString("@microsoft.graph.downloadUrl").ifEmpty {
            throw OneDriveException("Sin enlace de descarga")
        }

    fun itemUri(itemId: String): String = Uri.Builder().scheme("onedrive").authority("item").appendPath(itemId).build().toString()

    private fun random(n: Int): String = ByteArray(n).also { SecureRandom().nextBytes(it) }.let(::b64)
    private fun b64(b: ByteArray) = Base64.encodeToString(b, Base64.URL_SAFE or Base64.NO_WRAP or Base64.NO_PADDING)
}
