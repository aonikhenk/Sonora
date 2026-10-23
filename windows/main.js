// Sonora para Windows — proceso principal (archivos, OneDrive, ventana)
const { app, BrowserWindow, ipcMain, dialog, safeStorage, shell, nativeImage } = require('electron')
const path = require('path')
const fs = require('fs')
const fsp = require('fs/promises')
const crypto = require('crypto')
const { pathToFileURL } = require('url')
const { Readable } = require('stream')
const { pipeline } = require('stream/promises')

const AUDIO_EXT = new Set(['flac', 'wav', 'wave', 'aif', 'aiff', 'm4a', 'alac', 'mp3', 'aac', 'ogg', 'opus'])
const IMAGE_EXT = new Set(['jpg', 'jpeg', 'png'])

const DATA = app.getPath('userData')
const ART_DIR = path.join(DATA, 'Artwork')
const OFFLINE_DIR = path.join(DATA, 'Offline')
const STORE = path.join(DATA, 'library.json')
const TOKEN = path.join(DATA, 'onedrive.token')
const SETTINGS = path.join(DATA, 'settings.json')

const WIDTH = 420
const BASE_HEIGHT = 52 + 420 + 52
const LIBRARY_HEIGHT = 380

let win = null
let store = { folders: [], tracks: {}, artwork: {}, oneDriveFolder: null, account: null }
let settings = { floating: false }

// ---------- utilidades ----------

const ext = (name) => path.extname(name).slice(1).toLowerCase()
const hash = (s) => crypto.createHash('md5').update(s).digest('hex')
const leadingNumber = (s) => { const m = /^\d+/.exec(s); return m ? parseInt(m[0], 10) : 0 }
function parseName(fileName) {
  const base = fileName.replace(/\.[^.]+$/, '')
  const num = leadingNumber(base)
  const title = base.replace(/^\d+/, '').replace(/^[\s.\-_)]+/, '').trim() || base
  return { num, title }
}
function readJSON(file, fallback) {
  try { return JSON.parse(fs.readFileSync(file, 'utf8')) } catch { return fallback }
}
let saveTimer = null
function save() {
  clearTimeout(saveTimer)
  saveTimer = setTimeout(() => fs.writeFile(STORE, JSON.stringify(store), () => {}), 400)
}
function send(channel, payload) { win?.webContents.send(channel, payload) }
function status(text) { send('status', text) }

function albumKey(t) {
  return t.groupKey || ((t.albumArtist || t.artist) + '|' + t.album).toLowerCase()
}
function artworkFile(key) { return store.artwork[key] ? path.join(ART_DIR, store.artwork[key]) : null }
function saveArtwork(key, data) {
  if (!data || data.length < 100) return
  const name = hash(key) + '.img'
  fs.writeFileSync(path.join(ART_DIR, name), data)
  store.artwork[key] = name
}

function offlinePath(t) {
  return path.join(OFFLINE_DIR, t.path.replace(/[^\w.-]/g, '_') + '.' + (t.format === 'alac' ? 'm4a' : t.format))
}

/** Biblioteca para la interfaz: álbumes con sus canciones ordenadas. */
function snapshot() {
  const groups = new Map()
  for (const t of Object.values(store.tracks)) {
    const key = albumKey(t)
    if (!groups.has(key)) groups.set(key, [])
    groups.get(key).push(t)
  }
  const albums = []
  for (const [key, tracks] of groups) {
    tracks.sort((a, b) => (a.disc - b.disc) || (a.track - b.track) || a.title.localeCompare(b.title))
    const art = artworkFile(key)
    albums.push({
      id: key,
      title: tracks[0].album,
      artist: tracks[0].albumArtist || tracks[0].artist,
      year: tracks.find((t) => t.year)?.year || null,
      art: art ? pathToFileURL(art).href : null,
      oneDrive: !!tracks[0].oneDrive,
      tracks: tracks.map((t) => ({ ...t, offline: t.oneDrive ? fs.existsSync(offlinePath(t)) : false })),
    })
  }
  albums.sort((a, b) => a.artist.toLowerCase().localeCompare(b.artist.toLowerCase()) || a.title.toLowerCase().localeCompare(b.title.toLowerCase()))
  return {
    albums,
    oneDrive: { signedIn: !!readToken(), account: store.account, folder: store.oneDriveFolder, configured: !!clientId() },
  }
}
function publish() { send('library', snapshot()) }

// ---------- etiquetas ----------

let mm = null
async function metadata() { return (mm ??= await import('music-metadata')) }

async function readTrack(file) {
  const { parseFile } = await metadata()
  const name = path.basename(file)
  const folder = path.basename(path.dirname(file))
  const { num, title } = parseName(name)
  let m = null
  try { m = await parseFile(file, { duration: false, skipCovers: false }) } catch { /* sin etiquetas */ }
  const c = m?.common || {}
  const f = m?.format || {}
  const fmt = ext(name)
  const t = {
    path: file,
    title: c.title || title,
    artist: c.artist || c.albumartist || 'Artista desconocido',
    albumArtist: c.albumartist || null,
    album: c.album || folder,
    track: c.track?.no || num,
    disc: c.disk?.no || 1,
    year: c.year ? String(c.year) : null,
    duration: f.duration || 0,
    sampleRate: f.sampleRate || 0,
    bitDepth: f.bitsPerSample || 0,
    format: fmt === 'm4a' && f.codec === 'ALAC' ? 'alac' : fmt,
  }
  return { track: t, cover: c.picture?.[0]?.data }
}

async function folderCover(dir) {
  try {
    const files = (await fsp.readdir(dir)).filter((n) => IMAGE_EXT.has(ext(n)))
    const pick = files.find((n) => /^(cover|folder|front|album|artwork)\./i.test(n)) || files[0]
    return pick ? await fsp.readFile(path.join(dir, pick)) : null
  } catch { return null }
}

async function listAudio(root) {
  const out = []
  async function walk(p) {
    let st
    try { st = await fsp.stat(p) } catch { return }
    if (st.isDirectory()) {
      let entries = []
      try { entries = await fsp.readdir(p) } catch { return }
      for (const e of entries) if (!e.startsWith('.')) await walk(path.join(p, e))
    } else if (AUDIO_EXT.has(ext(p))) out.push(p)
  }
  await walk(root)
  return out
}

let scanning = false
async function scan(paths) {
  if (scanning) return
  scanning = true
  try {
    status('Buscando archivos…')
    const files = []
    for (const p of paths) files.push(...(await listAudio(p)))
    let done = 0
    for (const file of files) {
      const r = await readTrack(file)
      store.tracks[file] = r.track
      const key = albumKey(r.track)
      if (!store.artwork[key]) saveArtwork(key, r.cover || (await folderCover(path.dirname(file))))
      if (++done % 10 === 0) { status(`Leyendo ${done} de ${files.length}…`); publish() }
    }
    save()
  } finally {
    scanning = false
    status('')
    publish()
  }
}

// ---------- OneDrive (Microsoft Graph, OAuth 2.0 + PKCE) ----------

const AUTHORITY = 'https://login.microsoftonline.com/common/oauth2/v2.0'
const GRAPH = 'https://graph.microsoft.com/v1.0'
const REDIRECT = 'sonora://auth'
const SCOPES = 'Files.Read offline_access User.Read'
function clientId() {
  return readJSON(path.join(__dirname, 'secrets.json'), {}).oneDriveClientId || ''
}

function readToken() {
  try {
    const raw = fs.readFileSync(TOKEN)
    return safeStorage.isEncryptionAvailable() ? safeStorage.decryptString(raw) : raw.toString()
  } catch { return null }
}
function writeToken(t) {
  if (!t) { try { fs.unlinkSync(TOKEN) } catch {} return }
  fs.writeFileSync(TOKEN, safeStorage.isEncryptionAvailable() ? safeStorage.encryptString(t) : t)
}

let access = null
let accessExpires = 0
async function tokenRequest(params) {
  const body = new URLSearchParams({ ...params, client_id: clientId(), scope: SCOPES })
  const r = await fetch(AUTHORITY + '/token', { method: 'POST', body })
  const j = await r.json().catch(() => ({}))
  if (!r.ok || !j.access_token) {
    if (params.grant_type === 'refresh_token' && r.status === 400) writeToken(null)
    throw new Error(j.error_description || 'Error de autenticación (' + r.status + ')')
  }
  access = j.access_token
  accessExpires = Date.now() + (j.expires_in - 120) * 1000
  if (j.refresh_token) writeToken(j.refresh_token)
}
async function token() {
  if (access && Date.now() < accessExpires) return access
  const refresh = readToken()
  if (!refresh) throw new Error('Inicia sesión en OneDrive.')
  await tokenRequest({ grant_type: 'refresh_token', refresh_token: refresh })
  return access
}
async function graph(urlOrPath) {
  const url = urlOrPath.startsWith('http') ? urlOrPath : GRAPH + urlOrPath
  const r = await fetch(url, { headers: { Authorization: 'Bearer ' + (await token()) } })
  if (!r.ok) throw new Error('OneDrive respondió ' + r.status)
  return r.json()
}
async function children(folderId) {
  let next = (folderId ? `/me/drive/items/${encodeURIComponent(folderId)}/children` : '/me/drive/root/children') + '?$top=200&$expand=thumbnails'
  const out = []
  while (next) {
    const page = await graph(next)
    out.push(...page.value)
    next = page['@odata.nextLink'] || null
  }
  return out
}
async function downloadUrl(itemId) {
  const j = await graph(`/me/drive/items/${encodeURIComponent(itemId)}`)
  if (!j['@microsoft.graph.downloadUrl']) throw new Error('Sin enlace de descarga')
  return j['@microsoft.graph.downloadUrl']
}

/** Abre la ventana de inicio de sesión de Microsoft y espera el regreso a sonora://auth. */
function signIn() {
  return new Promise((resolve, reject) => {
    const b64 = (buf) => buf.toString('base64url')
    const verifier = b64(crypto.randomBytes(48))
    const challenge = b64(crypto.createHash('sha256').update(verifier).digest())
    const state = b64(crypto.randomBytes(18))
    const url = new URL(AUTHORITY + '/authorize')
    url.search = new URLSearchParams({
      client_id: clientId(), response_type: 'code', redirect_uri: REDIRECT, response_mode: 'query',
      scope: SCOPES, state, code_challenge: challenge, code_challenge_method: 'S256', prompt: 'select_account',
    }).toString()

    const auth = new BrowserWindow({
      width: 480, height: 680, parent: win, modal: true, title: 'Iniciar sesión en OneDrive',
      autoHideMenuBar: true, webPreferences: { partition: 'persist:onedrive' },
    })
    let finished = false
    const handle = async (event, target) => {
      if (!target.startsWith(REDIRECT)) return
      event.preventDefault()
      finished = true
      auth.destroy()
      const q = new URL(target).searchParams
      try {
        if (q.get('error')) throw new Error(q.get('error_description') || q.get('error'))
        if (q.get('state') !== state || !q.get('code')) throw new Error('Respuesta inválida, intenta de nuevo.')
        await tokenRequest({ grant_type: 'authorization_code', code: q.get('code'), redirect_uri: REDIRECT, code_verifier: verifier })
        try {
          const me = await graph('/me')
          store.account = me.userPrincipalName || me.displayName
          save()
        } catch {}
        resolve(true)
      } catch (e) { reject(e) }
    }
    auth.webContents.on('will-redirect', handle)
    auth.webContents.on('will-navigate', handle)
    auth.on('closed', () => { if (!finished) resolve(false) })
    auth.loadURL(url.toString())
  })
}

let readingOneDrive = false
async function refreshOneDrive() {
  const root = store.oneDriveFolder
  if (!root || !readToken() || readingOneDrive) return
  readingOneDrive = true
  try {
    const found = {}
    const covers = {}
    const pending = [{ id: root.id, path: [] }]
    let folders = 0
    while (pending.length) {
      const { id, path: p } = pending.shift()
      const items = await children(id)
      status(`OneDrive: ${++folders} carpetas, ${Object.keys(found).length} canciones`)
      const groupKey = 'od:' + id
      let cover = null
      let thumb = null
      for (const it of items) {
        if (it.folder) { pending.push({ id: it.id, path: [...p, it.name] }); continue }
        const e = ext(it.name)
        if (IMAGE_EXT.has(e)) {
          if (!cover || /^(cover|folder|front)\./i.test(it.name)) cover = it['@microsoft.graph.downloadUrl']
          continue
        }
        if (!AUDIO_EXT.has(e)) continue
        const { num, title } = parseName(it.name)
        let album = p[p.length - 1] || root.name
        let artist = p.length >= 2 ? p[p.length - 2] : 'Artista desconocido'
        if (p.length < 2 && album.includes(' - ')) [artist, album] = [album.split(' - ')[0], album.split(' - ').slice(1).join(' - ')]
        const a = it.audio || {}
        const id2 = 'od:' + it.id
        const old = store.tracks[id2]
        found[id2] = old?.sampleRate ? old : {
          path: it.id, oneDrive: true, groupKey,
          title: a.title || title, artist: a.albumArtist || a.artist || artist, albumArtist: a.albumArtist || null,
          album: a.album || album, track: a.track || num, disc: a.disc || 1, year: a.year ? String(a.year) : null,
          duration: (a.duration || 0) / 1000, sampleRate: 0, bitDepth: 0, format: e,
        }
        if (!thumb) thumb = it.thumbnails?.[0]?.large?.url || it.thumbnails?.[0]?.medium?.url || null
      }
      if ((cover || thumb) && !store.artwork[groupKey]) covers[groupKey] = cover || thumb
    }
    for (const [k, t] of Object.entries(store.tracks)) if (t.oneDrive) delete store.tracks[k]
    Object.assign(store.tracks, found)
    publish()
    let i = 0
    for (const [key, url] of Object.entries(covers)) {
      status(`Carátulas ${++i} de ${Object.keys(covers).length}…`)
      try { const r = await fetch(url); if (r.ok) saveArtwork(key, Buffer.from(await r.arrayBuffer())) } catch {}
      if (i % 10 === 0) publish()
    }
    save()
  } catch (e) {
    send('error', e.message)
  } finally {
    readingOneDrive = false
    status('')
    publish()
  }
}

/** Descarga una canción de OneDrive al PC y completa sus etiquetas. */
async function makeOffline(t) {
  const dest = offlinePath(t)
  if (fs.existsSync(dest)) return true
  const url = await downloadUrl(t.path)
  const r = await fetch(url)
  if (!r.ok || !r.body) return false
  const tmp = dest + '.part'
  await pipeline(Readable.fromWeb(r.body), fs.createWriteStream(tmp))
  await fsp.rename(tmp, dest)
  // Etiquetas reales (calidad, carátula) desde el archivo descargado
  try {
    const { track, cover } = await readTrack(dest)
    const id = 'od:' + t.path
    const cur = store.tracks[id]
    if (cur) {
      Object.assign(cur, {
        sampleRate: track.sampleRate, bitDepth: track.bitDepth, duration: track.duration || cur.duration,
        title: track.title !== parseName(path.basename(dest)).title ? track.title : cur.title,
      })
      if (cover && !store.artwork[cur.groupKey]) saveArtwork(cur.groupKey, cover)
    }
  } catch {}
  return true
}

// ---------- IPC ----------

ipcMain.handle('library:get', () => snapshot())
ipcMain.handle('library:add', async (_e, paths) => {
  for (const p of paths) {
    try { if (fs.statSync(p).isDirectory() && !store.folders.includes(p)) store.folders.push(p) } catch {}
  }
  save()
  scan(paths)
})
ipcMain.handle('library:choose', async () => {
  const r = await dialog.showOpenDialog(win, { title: 'Agregar música', properties: ['openDirectory', 'multiSelections'] })
  if (!r.canceled && r.filePaths.length) {
    for (const p of r.filePaths) if (!store.folders.includes(p)) store.folders.push(p)
    save()
    scan(r.filePaths)
  }
})
ipcMain.handle('library:rescan', async () => {
  for (const [k, t] of Object.entries(store.tracks)) if (!t.oneDrive && !fs.existsSync(t.path)) delete store.tracks[k]
  publish()
  await scan(store.folders.filter((f) => fs.existsSync(f)))
  refreshOneDrive()
})
ipcMain.handle('library:remove', (_e, albumId) => {
  for (const [k, t] of Object.entries(store.tracks)) if (albumKey(t) === albumId && !t.oneDrive) delete store.tracks[k]
  save()
  publish()
})
ipcMain.handle('library:reveal', (_e, file) => shell.showItemInFolder(file))

ipcMain.handle('track:source', async (_e, t) => {
  if (!t.oneDrive) return pathToFileURL(t.path).href
  const off = offlinePath(t)
  if (fs.existsSync(off)) return pathToFileURL(off).href
  return downloadUrl(t.path)
})

ipcMain.handle('onedrive:signin', async () => signIn())
ipcMain.handle('onedrive:signout', () => {
  writeToken(null)
  access = null
  store.account = null
  store.oneDriveFolder = null
  for (const [k, t] of Object.entries(store.tracks)) if (t.oneDrive) delete store.tracks[k]
  fs.rmSync(OFFLINE_DIR, { recursive: true, force: true })
  fs.mkdirSync(OFFLINE_DIR, { recursive: true })
  save()
  publish()
})
ipcMain.handle('onedrive:children', async (_e, id) =>
  (await children(id)).map((i) => ({ id: i.id, name: i.name, folder: !!i.folder, audio: AUDIO_EXT.has(ext(i.name)) })))
ipcMain.handle('onedrive:use', (_e, folder) => {
  store.oneDriveFolder = folder
  for (const [k, t] of Object.entries(store.tracks)) if (t.oneDrive) delete store.tracks[k]
  save()
  publish()
  refreshOneDrive()
})
ipcMain.handle('onedrive:refresh', () => refreshOneDrive())

const downloading = new Set()
ipcMain.handle('offline:download', async (_e, albumId) => {
  if (downloading.has(albumId)) return
  downloading.add(albumId)
  const todo = Object.values(store.tracks).filter((t) => t.oneDrive && albumKey(t) === albumId && !fs.existsSync(offlinePath(t)))
  let failed = 0
  for (let i = 0; i < todo.length; i++) {
    send('download', { album: albumId, done: i, total: todo.length })
    try { if (!(await makeOffline(todo[i]))) failed++ } catch { failed++ }
  }
  downloading.delete(albumId)
  send('download', { album: albumId, done: todo.length, total: todo.length, finished: true })
  save()
  publish()
  if (failed) send('error', `No se pudieron descargar ${failed} canciones. Revisa la conexión e inténtalo de nuevo.`)
})
ipcMain.handle('offline:remove', (_e, albumId) => {
  for (const t of Object.values(store.tracks)) if (t.oneDrive && albumKey(t) === albumId) { try { fs.unlinkSync(offlinePath(t)) } catch {} }
  publish()
})

ipcMain.handle('window:library', (_e, open) => {
  win.setContentSize(WIDTH, BASE_HEIGHT + (open ? LIBRARY_HEIGHT : 0), true)
})
ipcMain.handle('window:floating', (_e, on) => {
  settings.floating = on
  win.setAlwaysOnTop(on, 'floating')
  fs.writeFile(SETTINGS, JSON.stringify(settings), () => {})
  return on
})
ipcMain.handle('window:settings', () => settings)
ipcMain.handle('window:minimize', () => win.minimize())
ipcMain.handle('window:close', () => win.close())

// ---------- ventana ----------

function createWindow() {
  win = new BrowserWindow({
    width: WIDTH,
    height: BASE_HEIGHT,
    useContentSize: true,
    resizable: false,
    maximizable: false,
    fullscreenable: false,
    frame: false,
    backgroundColor: '#13152a',
    title: 'Sonora',
    icon: path.join(__dirname, 'src', 'icon.png'),
    alwaysOnTop: settings.floating,
    webPreferences: { preload: path.join(__dirname, 'preload.js'), contextIsolation: true, sandbox: true },
  })
  win.setMenu(null)
  win.loadFile(path.join(__dirname, 'src', 'index.html'))
  // Solo para pruebas automáticas: SONORA_SCREENSHOT=archivo.png
  if (process.env.SONORA_SCREENSHOT) {
    win.webContents.once('did-finish-load', () => setTimeout(async () => {
      if (process.env.SONORA_JS) await win.webContents.executeJavaScript(process.env.SONORA_JS).catch((e) => console.error(e))
      setTimeout(async () => {
        const img = await win.webContents.capturePage()
        fs.writeFileSync(process.env.SONORA_SCREENSHOT, img.toPNG())
        app.quit()
      }, Number(process.env.SONORA_WAIT || 1500))
    }, 800))
  }
  // Enlaces externos en el navegador
  win.webContents.setWindowOpenHandler(({ url }) => { shell.openExternal(url); return { action: 'deny' } })
}

// La música puede empezar sola (al elegir una canción de OneDrive tarda unos segundos en llegar el enlace)
app.commandLine.appendSwitch('autoplay-policy', 'no-user-gesture-required')

if (!app.requestSingleInstanceLock()) app.quit()
app.on('second-instance', () => { if (win) { if (win.isMinimized()) win.restore(); win.focus() } })

app.whenReady().then(() => {
  app.setAppUserModelId('cl.zanetta.sonora')
  for (const d of [ART_DIR, OFFLINE_DIR]) fs.mkdirSync(d, { recursive: true })
  store = { ...store, ...readJSON(STORE, {}) }
  settings = { ...settings, ...readJSON(SETTINGS, {}) }
  createWindow()
})
app.on('window-all-closed', () => app.quit())
