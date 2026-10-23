import Foundation
import AuthenticationServices
import CryptoKit
import Security
import AppKit

// MARK: - Configuración (registro de la app en Microsoft Entra / Azure)

enum OneDriveConfig {
    static let clientID = Secrets.oneDriveClientID   // ver Secrets.swift (no se sube a GitHub)
    static let redirectURI = "sonora://auth"
    static let scopes = "Files.Read offline_access User.Read"
    static let authority = "https://login.microsoftonline.com/common/oauth2/v2.0"
    static let graph = "https://graph.microsoft.com/v1.0"
}

struct DriveItem: Decodable {
    struct FileFacet: Decodable { let mimeType: String? }
    struct FolderFacet: Decodable { let childCount: Int? }
    struct AudioFacet: Decodable {
        let album: String?
        let albumArtist: String?
        let artist: String?
        let title: String?
        let track: Int?
        let disc: Int?
        let year: Int?
        let duration: Int?      // milisegundos
    }
    struct ThumbnailSet: Decodable {
        struct Thumb: Decodable { let url: String? }
        let large: Thumb?
        let medium: Thumb?
    }

    let id: String
    let name: String
    let size: Int64?
    let file: FileFacet?
    let folder: FolderFacet?
    let audio: AudioFacet?
    let thumbnails: [ThumbnailSet]?
    let downloadURL: String?

    enum CodingKeys: String, CodingKey {
        case id, name, size, file, folder, audio, thumbnails
        case downloadURL = "@microsoft.graph.downloadUrl"
    }

    var thumbnailURL: URL? {
        (thumbnails?.first?.large?.url ?? thumbnails?.first?.medium?.url).flatMap(URL.init(string:))
    }
}

struct OneDriveFolder: Codable, Hashable {
    var id: String
    var name: String
}

enum OneDriveError: LocalizedError {
    case notSignedIn, cancelled, http(Int, String)
    var errorDescription: String? {
        switch self {
        case .notSignedIn: return "Inicia sesión en OneDrive."
        case .cancelled: return "Inicio de sesión cancelado."
        case .http(let code, let msg): return "OneDrive respondió \(code): \(msg)"
        }
    }
}

// MARK: - Cliente

@MainActor
final class OneDrive: NSObject, ObservableObject, ASWebAuthenticationPresentationContextProviding {
    static let shared = OneDrive()

    @Published private(set) var isSignedIn = false
    @Published private(set) var accountName: String?

    private var accessToken: String?
    private var expiresAt = Date.distantPast
    private var refreshToken: String? {
        get { TokenStore.read("onedrive.refresh") }
        set { if let newValue { TokenStore.write(newValue, for: "onedrive.refresh") } else { TokenStore.delete("onedrive.refresh") } }
    }
    private var authSession: ASWebAuthenticationSession?

    override init() {
        super.init()
        isSignedIn = refreshToken != nil
        accountName = UserDefaults.standard.string(forKey: "onedrive.account")
    }

    // MARK: Inicio de sesión (OAuth 2.0 + PKCE, sin secreto)

    func signIn() async throws {
        let verifier = Self.randomString(64)
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URL
        let state = Self.randomString(24)

        var c = URLComponents(string: OneDriveConfig.authority + "/authorize")!
        c.queryItems = [
            .init(name: "client_id", value: OneDriveConfig.clientID),
            .init(name: "response_type", value: "code"),
            .init(name: "redirect_uri", value: OneDriveConfig.redirectURI),
            .init(name: "response_mode", value: "query"),
            .init(name: "scope", value: OneDriveConfig.scopes),
            .init(name: "state", value: state),
            .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "prompt", value: "select_account")
        ]

        let callback: URL = try await withCheckedThrowingContinuation { cont in
            let session = ASWebAuthenticationSession(url: c.url!, callbackURLScheme: "sonora") { url, error in
                if let url { cont.resume(returning: url) }
                else { cont.resume(throwing: (error as? ASWebAuthenticationSessionError)?.code == .canceledLogin ? OneDriveError.cancelled : (error ?? OneDriveError.cancelled)) }
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false
            authSession = session
            session.start()
        }

        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        if let err = items.first(where: { $0.name == "error_description" })?.value ?? items.first(where: { $0.name == "error" })?.value {
            throw OneDriveError.http(400, err)
        }
        guard items.first(where: { $0.name == "state" })?.value == state,
              let code = items.first(where: { $0.name == "code" })?.value else { throw OneDriveError.cancelled }

        try await requestToken([
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": OneDriveConfig.redirectURI,
            "code_verifier": verifier
        ])
        isSignedIn = true

        if let me: Me = try? await get("/me") {
            accountName = me.userPrincipalName ?? me.displayName
            UserDefaults.standard.set(accountName, forKey: "onedrive.account")
        }
    }

    func signOut() {
        refreshToken = nil
        accessToken = nil
        expiresAt = .distantPast
        isSignedIn = false
        accountName = nil
        UserDefaults.standard.removeObject(forKey: "onedrive.account")
    }

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated { NSApp.keyWindow ?? NSApp.windows.first ?? ASPresentationAnchor() }
    }

    private struct Me: Decodable { let displayName: String?; let userPrincipalName: String? }

    private struct TokenResponse: Decodable {
        let access_token: String
        let refresh_token: String?
        let expires_in: Int
    }
    private struct TokenError: Decodable { let error: String?; let error_description: String? }

    private func requestToken(_ params: [String: String]) async throws {
        var req = URLRequest(url: URL(string: OneDriveConfig.authority + "/token")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var all = params
        all["client_id"] = OneDriveConfig.clientID
        all["scope"] = OneDriveConfig.scopes
        req.httpBody = all.map { "\($0.key)=\($0.value.formEncoded)" }.joined(separator: "&").data(using: .utf8)

        let (data, resp) = try await URLSession.shared.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200, let tok = try? JSONDecoder().decode(TokenResponse.self, from: data) else {
            let e = try? JSONDecoder().decode(TokenError.self, from: data)
            throw OneDriveError.http(status, e?.error_description ?? e?.error ?? "error de autenticación")
        }
        accessToken = tok.access_token
        expiresAt = Date().addingTimeInterval(TimeInterval(tok.expires_in - 120))
        if let r = tok.refresh_token { refreshToken = r }
    }

    private func token() async throws -> String {
        if let accessToken, Date() < expiresAt { return accessToken }
        guard let refresh = refreshToken else { throw OneDriveError.notSignedIn }
        do {
            try await requestToken(["grant_type": "refresh_token", "refresh_token": refresh])
        } catch OneDriveError.http(let code, let msg) where code == 400 {
            signOut()
            throw OneDriveError.http(code, msg)
        }
        return accessToken!
    }

    // MARK: Microsoft Graph

    private struct Page: Decodable {
        let value: [DriveItem]
        let next: String?
        enum CodingKeys: String, CodingKey { case value; case next = "@odata.nextLink" }
    }

    private func get<T: Decodable>(_ pathOrURL: String) async throws -> T {
        let url = pathOrURL.hasPrefix("http") ? URL(string: pathOrURL)! : URL(string: OneDriveConfig.graph + pathOrURL)!
        var req = URLRequest(url: url)
        req.setValue("Bearer " + (try await token()), forHTTPHeaderField: "Authorization")
        let (data, resp) = try await URLSession.shared.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw OneDriveError.http(status, String(data: data, encoding: .utf8)?.prefix(200).description ?? "")
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    /// Contenido de una carpeta (nil = raíz de OneDrive).
    func children(of folderID: String?) async throws -> [DriveItem] {
        var next: String? = (folderID.map { "/me/drive/items/\($0)/children" } ?? "/me/drive/root/children")
            + "?$top=200&$expand=thumbnails"
        var out: [DriveItem] = []
        while let n = next {
            let page: Page = try await get(n)
            out += page.value
            next = page.next
        }
        return out
    }

    /// Enlace directo de descarga (válido ~1 hora, no necesita encabezado de autorización).
    func downloadURL(itemID: String) async throws -> URL {
        let item: DriveItem = try await get("/me/drive/items/\(itemID)")
        guard let s = item.downloadURL, let u = URL(string: s) else { throw OneDriveError.http(404, "sin enlace de descarga") }
        return u
    }

    // MARK: Utilidades

    private static func randomString(_ n: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: n)
        _ = SecRandomCopyBytes(kSecRandomDefault, n, &bytes)
        return Data(bytes).base64URL
    }
}

// MARK: - Caché local de canciones de OneDrive

enum OneDriveCache {
    static let limitBytes: Int64 = 3 * 1024 * 1024 * 1024   // 3 GB

    static var dir: URL = {
        let d = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Sonora/OneDrive", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    /// Canciones descargadas para escuchar sin internet (no se borran solas ni van al respaldo de iCloud).
    static var offlineDir: URL = {
        var d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Sonora/Offline", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        var v = URLResourceValues()
        v.isExcludedFromBackup = true
        try? d.setResourceValues(v)
        return d
    }()

    private static func fileName(_ itemID: String, _ ext: String) -> String {
        itemID.replacingOccurrences(of: "!", with: "_") + "." + (ext == "alac" ? "m4a" : ext)
    }
    static func cacheURL(itemID: String, ext: String) -> URL { dir.appendingPathComponent(fileName(itemID, ext)) }
    static func offlineURL(itemID: String, ext: String) -> URL { offlineDir.appendingPathComponent(fileName(itemID, ext)) }

    /// Archivo a reproducir: la copia descargada si existe; si no, el caché.
    static func url(itemID: String, ext: String) -> URL {
        let o = offlineURL(itemID: itemID, ext: ext)
        return FileManager.default.fileExists(atPath: o.path) ? o : cacheURL(itemID: itemID, ext: ext)
    }

    static func isOffline(_ t: Track) -> Bool {
        FileManager.default.fileExists(atPath: offlineURL(itemID: t.path, ext: t.format).path)
    }

    /// Guarda la canción de forma permanente (reutiliza el caché si ya estaba).
    static func makeOffline(_ t: Track) async -> Bool {
        let dest = offlineURL(itemID: t.path, ext: t.format)
        let fm = FileManager.default
        if fm.fileExists(atPath: dest.path) { return true }
        let cached = cacheURL(itemID: t.path, ext: t.format)
        if fm.fileExists(atPath: cached.path), (try? fm.copyItem(at: cached, to: dest)) != nil { return true }
        do {
            let src = try await OneDrive.shared.downloadURL(itemID: t.path)
            let (tmp, resp) = try await URLSession.shared.download(from: src)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else { return false }
            try? fm.removeItem(at: dest)
            try fm.moveItem(at: tmp, to: dest)
            return true
        } catch { return false }
    }

    static func removeOffline(_ t: Track) {
        try? FileManager.default.removeItem(at: offlineURL(itemID: t.path, ext: t.format))
    }

    static func clearOffline() {
        try? FileManager.default.removeItem(at: offlineDir)
        try? FileManager.default.createDirectory(at: offlineDir, withIntermediateDirectories: true)
    }

    static func isCached(_ t: Track) -> Bool { FileManager.default.fileExists(atPath: t.url.path) }

    private static let downloads = DownloadRegistry()

    /// Descarga la canción al caché (una sola descarga por canción aunque se pida varias veces).
    static func download(_ t: Track) async -> Bool {
        if isCached(t) { touch(t.url); return true }
        return await downloads.run(key: t.path) {
            do {
                let src = try await OneDrive.shared.downloadURL(itemID: t.path)
                let (tmp, resp) = try await URLSession.shared.download(from: src)
                guard (resp as? HTTPURLResponse)?.statusCode == 200 else { return false }
                try? FileManager.default.removeItem(at: t.url)
                try FileManager.default.moveItem(at: tmp, to: t.url)
                trim()
                return true
            } catch { return false }
        }
    }

    static func touch(_ url: URL) {
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
    }

    /// Borra las canciones menos usadas cuando el caché supera el límite.
    static func trim() {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys) else { return }
        var entries = files.compactMap { u -> (URL, Int64, Date)? in
            guard let v = try? u.resourceValues(forKeys: Set(keys)) else { return nil }
            return (u, Int64(v.fileSize ?? 0), v.contentModificationDate ?? .distantPast)
        }
        var total = entries.reduce(0) { $0 + $1.1 }
        entries.sort { $0.2 < $1.2 }
        for e in entries where total > limitBytes {
            try? FileManager.default.removeItem(at: e.0)
            total -= e.1
        }
    }

    static func clear() {
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    static var sizeDescription: String {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        let total = files.reduce(Int64(0)) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        return ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
    }
}

actor DownloadRegistry {
    private var running: [String: Task<Bool, Never>] = [:]

    func run(key: String, _ op: @escaping @Sendable () async -> Bool) async -> Bool {
        if let t = running[key] { return await t.value }
        let t = Task { await op() }
        running[key] = t
        let r = await t.value
        running[key] = nil
        return r
    }
}

// MARK: - Token guardado en un archivo privado (evita avisos del llavero en cada compilación)

enum TokenStore {
    private static let dir: URL = {
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Sonora", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()
    private static func file(_ key: String) -> URL { dir.appendingPathComponent("." + key) }

    static func write(_ value: String, for key: String) {
        let f = file(key)
        try? Data(value.utf8).write(to: f, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: f.path)
    }
    static func read(_ key: String) -> String? { (try? Data(contentsOf: file(key))).flatMap { String(data: $0, encoding: .utf8) } }
    static func delete(_ key: String) { try? FileManager.default.removeItem(at: file(key)) }
}

extension Data {
    var base64URL: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}

extension String {
    var formEncoded: String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return addingPercentEncoding(withAllowedCharacters: allowed) ?? self
    }
}
