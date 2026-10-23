// Sonora para Windows — interfaz y reproductor
const $ = (id) => document.getElementById(id)
const api = window.sonora

// ---------- íconos ----------
const svg = (d, size = 18, extra = '') =>
  `<svg width="${size}" height="${size}" viewBox="0 0 24 24" fill="currentColor" ${extra}><path d="${d}"/></svg>`
const I = {
  play: (s) => svg('M8 5v14l11-7z', s),
  pause: (s) => svg('M6 19h4V5H6v14zm8-14v14h4V5h-4z', s),
  prev: (s) => svg('M6 6h2v12H6zm3.5 6 8.5 6V6z', s),
  next: (s) => svg('M6 18l8.5-6L6 6v12zM16 6v12h2V6h-2z', s),
  note: (s) => svg('M12 3v10.55c-.59-.34-1.27-.55-2-.55-2.21 0-4 1.79-4 4s1.79 4 4 4 4-1.79 4-4V7h4V3h-6z', s),
  back: (s) => svg('M15.41 7.41 14 6l-6 6 6 6 1.41-1.41L10.83 12z', s),
  pin: (s) => svg('M16 9V4h1c.55 0 1-.45 1-1s-.45-1-1-1H7c-.55 0-1 .45-1 1s.45 1 1 1h1v5c0 1.66-1.34 3-3 3v2h5.97v7l1 1 1-1v-7H19v-2c-1.66 0-3-1.34-3-3z', s),
  min: (s) => svg('M5 11h14v2H5z', s),
  close: (s) => svg('M19 6.41 17.59 5 12 10.59 6.41 5 5 6.41 10.59 12 5 17.59 6.41 19 12 13.41 17.59 19 19 17.59 13.41 12z', s),
  cloud: (s) => svg('M19.35 10.04C18.67 6.59 15.64 4 12 4 9.11 4 6.6 5.64 5.35 8.04 2.34 8.36 0 10.91 0 14c0 3.31 2.69 6 6 6h13c2.76 0 5-2.24 5-5 0-2.64-2.05-4.78-4.65-4.96z', s),
  plus: (s) => svg('M19 13h-6v6h-2v-6H5v-2h6V5h2v6h6v2z', s),
  refresh: (s) => svg('M17.65 6.35A7.958 7.958 0 0 0 12 4c-4.42 0-7.99 3.58-7.99 8s3.57 8 7.99 8c3.73 0 6.84-2.55 7.73-6h-2.08A5.99 5.99 0 0 1 12 18c-3.31 0-6-2.69-6-6s2.69-6 6-6c1.66 0 3.14.69 4.22 1.78L13 11h7V4l-2.35 2.35z', s),
  search: (s) => svg('M15.5 14h-.79l-.28-.27A6.471 6.471 0 0 0 16 9.5 6.5 6.5 0 1 0 9.5 16c1.61 0 3.09-.59 4.23-1.57l.27.28v.79l5 4.99L20.49 19l-4.99-5zm-6 0C7.01 14 5 11.99 5 9.5S7.01 5 9.5 5 14 7.01 14 9.5 11.99 14 9.5 14z', s),
  folder: (s) => svg('M10 4H4c-1.1 0-2 .9-2 2v12c0 1.1.9 2 2 2h16c1.1 0 2-.9 2-2V8c0-1.1-.9-2-2-2h-8l-2-2z', s),
  folderPlus: (s) => svg('M20 6h-8l-2-2H4c-1.1 0-1.99.9-1.99 2L2 18c0 1.1.9 2 2 2h16c1.1 0 2-.9 2-2V8c0-1.1-.9-2-2-2zm-1 8h-3v3h-2v-3h-3v-2h3V9h2v3h3v2z', s),
  speaker: (s) => svg('M3 9v6h4l5 5V4L7 9H3zm13.5 3A4.5 4.5 0 0 0 14 7.97v8.05c1.48-.73 2.5-2.25 2.5-4.02z', s),
  down: (s) => svg('M20 12l-1.41-1.41L13 16.17V4h-2v12.17l-5.58-5.59L4 12l8 8 8-8z', s),
  check: (s) => svg('M9 16.17 4.83 12l-1.42 1.41L9 19 21 7l-1.41-1.41z', s),
  playCircle: (s) => svg('M12 2C6.48 2 2 6.48 2 12s4.48 10 10 10 10-4.48 10-10S17.52 2 12 2zm-2 14.5v-9l6 4.5-6 4.5z', s),
}

$('pin').innerHTML = I.pin(16)
$('min').innerHTML = I.min(16)
$('close').innerHTML = I.close(16)
$('prev').innerHTML = I.prev(20)
$('next').innerHTML = I.next(20)
$('play').innerHTML = I.play(30)
$('note').innerHTML = I.note(24)
$('cloudBtn').innerHTML = I.cloud(16)
$('addBtn').innerHTML = I.plus(17)
$('rescanBtn').innerHTML = I.refresh(16)
document.querySelector('.icon.search').innerHTML = I.search(15)
document.querySelector('.icon.folderplus').innerHTML = I.folderPlus(34)

// ---------- utilidades ----------
const esc = (s) => String(s ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c])
function fmtTime(sec) {
  const t = Math.max(0, Math.floor(isFinite(sec) ? sec : 0))
  const h = Math.floor(t / 3600), m = Math.floor(t / 60) % 60, s = t % 60
  return h ? `${h}:${String(m).padStart(2, '0')}:${String(s).padStart(2, '0')}` : `${m}:${String(s).padStart(2, '0')}`
}
const pad2 = (n) => String(n).padStart(2, '0')
function quality(t) {
  if (!t) return ''
  const f = (t.format || '').toUpperCase()
  if (!t.sampleRate) return f
  const k = t.sampleRate / 1000
  const rate = Number.isInteger(k) ? String(k) : k.toFixed(1)
  return t.bitDepth ? `${f} ${t.bitDepth}/${rate}` : `${f} ${rate} kHz`
}
const isHiRes = (t) => t && (t.bitDepth > 16 || t.sampleRate > 48000)
const displayTitle = (t) => (t ? (t.track ? `${pad2(t.track)} - ${t.title}` : t.title) : '—')
const trackId = (t) => (t.oneDrive ? 'od:' : '') + t.path

let toastTimer = null
function toast(msg) {
  const el = $('toast')
  el.textContent = msg
  el.hidden = false
  clearTimeout(toastTimer)
  toastTimer = setTimeout(() => (el.hidden = true), 6000)
}
$('toast').onclick = () => ($('toast').hidden = true)

// ---------- estado ----------
let lib = { albums: [], oneDrive: {} }
let view = { mode: 'albums', album: null, picker: [] }
let downloads = {}
let libraryOpen = false

// ---------- reproductor ----------
const audio = new Audio()
audio.preload = 'auto'
const player = { queue: [], index: -1, loading: false, token: 0 }
const current = () => player.queue[player.index] || null
const nextTrack = () => player.queue[player.index + 1] || null

async function playQueue(tracks, i) {
  player.queue = tracks
  await startAt(i)
}

async function startAt(i, autoplay = true) {
  if (i < 0 || i >= player.queue.length) return stop()
  const token = ++player.token
  player.index = i
  setLoading(true)
  renderNow()
  try {
    const src = await api.source(current())
    if (token !== player.token) return
    audio.src = src
    if (autoplay) await audio.play()
  } catch (e) {
    if (token !== player.token) return
    setLoading(false)
    if (e?.name === 'NotAllowedError') return
    toast('No se pudo reproducir "' + (current()?.title || '') + '".')
    if (i + 1 < player.queue.length) startAt(i + 1)
  }
}

function stop() {
  player.token++
  audio.pause()
  audio.removeAttribute('src')
  audio.load()
  player.queue = []
  player.index = -1
  setLoading(false)
  renderNow()
}

function togglePlay() {
  if (!current()) return
  if (audio.paused) audio.play().catch(() => {})
  else audio.pause()
}
function next() { if (player.index + 1 < player.queue.length) startAt(player.index + 1) }
function prev() {
  if (!current()) return
  if (audio.currentTime > 3 || player.index === 0) audio.currentTime = 0
  else startAt(player.index - 1)
}

function setLoading(on) {
  player.loading = on
  $('loading').hidden = !on
}

audio.addEventListener('playing', () => { setLoading(false); renderPlayState() })
audio.addEventListener('pause', renderPlayState)
audio.addEventListener('waiting', () => setLoading(true))
audio.addEventListener('canplay', () => setLoading(false))
audio.addEventListener('timeupdate', renderProgress)
audio.addEventListener('durationchange', renderProgress)
audio.addEventListener('ended', () => {
  if (player.index + 1 < player.queue.length) startAt(player.index + 1)
  else stop()
})
audio.addEventListener('error', () => {
  if (!current() || !audio.src) return
  setLoading(false)
  toast('No se pudo reproducir "' + current().title + '". Se salta a la siguiente.')
  if (player.index + 1 < player.queue.length) startAt(player.index + 1)
})

// Teclas multimedia y controles de Windows
navigator.mediaSession.setActionHandler('play', () => audio.play())
navigator.mediaSession.setActionHandler('pause', () => audio.pause())
navigator.mediaSession.setActionHandler('previoustrack', prev)
navigator.mediaSession.setActionHandler('nexttrack', next)
navigator.mediaSession.setActionHandler('seekto', (d) => { audio.currentTime = d.seekTime })
document.addEventListener('keydown', (e) => {
  if (e.target.tagName === 'INPUT') return
  if (e.code === 'Space') { e.preventDefault(); togglePlay() }
  if (e.ctrlKey && e.key === 'ArrowRight') next()
  if (e.ctrlKey && e.key === 'ArrowLeft') prev()
  if (e.ctrlKey && e.key.toLowerCase() === 'l') toggleLibrary()
  if (e.ctrlKey && e.key.toLowerCase() === 'o') api.choose()
})

// ---------- pantalla principal ----------
function albumOf(t) {
  if (!t) return null
  const id = trackId(t)
  return lib.albums.find((a) => a.tracks.some((x) => trackId(x) === id)) || null
}
function freshTrack(t) {
  if (!t) return null
  const id = trackId(t)
  for (const a of lib.albums) for (const x of a.tracks) if (trackId(x) === id) return x
  return t
}

function renderNow() {
  const t = freshTrack(current())
  const album = albumOf(t)
  $('art').classList.toggle('has-track', !!t)
  const cover = $('cover')
  if (t && album?.art) {
    if (cover.dataset.src !== album.art) { cover.src = album.art; cover.dataset.src = album.art }
    cover.classList.add('show')
    $('placeholder').hidden = true
  } else {
    cover.classList.remove('show')
    cover.dataset.src = ''
    $('placeholder').hidden = false
    $('placeholderText').textContent = t ? '' : lib.albums.length ? 'Elige un álbum en la biblioteca' : 'Arrastra aquí tu carpeta de música'
  }
  $('quality').textContent = quality(t)
  $('nowTitle').textContent = displayTitle(t)
  $('nextTitle').textContent = displayTitle(freshTrack(nextTrack()))
  document.title = t ? `${t.title} — Sonora` : 'Sonora'
  if (t) {
    navigator.mediaSession.metadata = new MediaMetadata({
      title: t.title, artist: t.artist, album: t.album,
      artwork: album?.art ? [{ src: album.art, sizes: '512x512' }] : [],
    })
  } else navigator.mediaSession.metadata = null
  renderPlayState()
  renderProgress()
  if (libraryOpen) renderLibrary()
}

function renderPlayState() {
  $('play').innerHTML = audio.paused ? I.play(30) : I.pause(30)
  navigator.mediaSession.playbackState = !current() ? 'none' : audio.paused ? 'paused' : 'playing'
}

let dragging = null
function renderProgress() {
  const t = current()
  const dur = isFinite(audio.duration) && audio.duration > 0 ? audio.duration : t?.duration || 0
  const frac = dragging ?? (dur > 0 ? Math.min(1, audio.currentTime / dur) : 0)
  $('progressFill').style.width = frac * 100 + '%'
  $('elapsed').textContent = fmtTime(frac * dur)
  $('remaining').textContent = '-' + fmtTime(dur * (1 - frac))
}

const progress = $('progress')
function fracAt(e) {
  const r = progress.getBoundingClientRect()
  return Math.min(1, Math.max(0, (e.clientX - r.left) / r.width))
}
progress.addEventListener('pointerdown', (e) => {
  progress.setPointerCapture(e.pointerId)
  dragging = fracAt(e)
  renderProgress()
})
progress.addEventListener('pointermove', (e) => { if (dragging !== null) { dragging = fracAt(e); renderProgress() } })
progress.addEventListener('pointerup', () => {
  if (dragging === null) return
  const dur = isFinite(audio.duration) ? audio.duration : current()?.duration || 0
  if (dur > 0) audio.currentTime = dragging * dur
  dragging = null
})

$('play').onclick = togglePlay
$('next').onclick = next
$('prev').onclick = prev
$('note').onclick = toggleLibrary
$('min').onclick = () => api.minimize()
$('close').onclick = () => api.close()
$('pin').onclick = async () => setPin(await api.setFloating(!$('pin').classList.contains('on')))
function setPin(on) {
  $('pin').classList.toggle('on', on)
  $('pin').title = on ? 'Dejar de mantener encima' : 'Mantener siempre encima'
}
api.settings().then((s) => setPin(!!s.floating))

// ---------- biblioteca ----------
function toggleLibrary(force) {
  libraryOpen = typeof force === 'boolean' ? force : !libraryOpen
  $('library').hidden = !libraryOpen
  $('note').classList.toggle('on', libraryOpen)
  api.setLibraryOpen(libraryOpen)
  if (libraryOpen) renderLibrary()
}

function showView(mode) {
  view.mode = mode
  $('albumsView').hidden = mode !== 'albums'
  $('detailView').hidden = mode !== 'detail'
  $('pickerView').hidden = mode !== 'picker'
  $('menu').hidden = true
}

function thumbHTML(a, cls = 'thumb') {
  return a.art ? `<img class="${cls}" src="${esc(a.art)}" alt="">` : `<div class="${cls}">${I.note(18)}</div>`
}

function renderLibrary() {
  if (view.mode === 'albums') renderAlbums()
  else if (view.mode === 'detail') renderDetail()
}

function renderAlbums() {
  const q = $('search').value.trim().toLowerCase()
  const list = q ? lib.albums.filter((a) => a.title.toLowerCase().includes(q) || a.artist.toLowerCase().includes(q)) : lib.albums
  $('empty').hidden = lib.albums.length > 0
  $('albums').hidden = lib.albums.length === 0
  const playing = albumOf(current())?.id
  $('albums').innerHTML = list.map((a) => {
    const first = a.tracks.find((t) => t.sampleRate) || a.tracks[0]
    const hi = a.tracks.some(isHiRes)
    return `<div class="album ${a.id === playing ? 'current' : ''}" data-id="${esc(a.id)}">
      ${thumbHTML(a)}
      <div class="meta"><div class="t ellipsis">${esc(a.title)}</div>
      <div class="s ellipsis">${esc([a.artist, a.year].filter(Boolean).join(' · '))}</div></div>
      <span class="qbadge ${hi ? 'hires' : ''}">${esc(a.oneDrive && !first.sampleRate ? 'ONEDRIVE' : quality(first))}</span>
    </div>`
  }).join('')
}

$('albums').addEventListener('click', (e) => {
  const el = e.target.closest('.album')
  if (!el) return
  view.album = el.dataset.id
  showView('detail')
  renderDetail()
})
$('albums').addEventListener('contextmenu', (e) => {
  const el = e.target.closest('.album')
  if (!el) return
  e.preventDefault()
  const a = lib.albums.find((x) => x.id === el.dataset.id)
  if (!a) return
  openMenu([
    ['Reproducir', () => playQueue(a.tracks, 0)],
    ...(a.oneDrive ? [] : [['Mostrar en el Explorador', () => api.reveal(a.tracks[0].path)], null,
      ['Quitar de la biblioteca', () => api.remove(a.id), 'danger']]),
  ], e.clientY - $('library').getBoundingClientRect().top)
})
$('search').addEventListener('input', renderAlbums)

function renderDetail() {
  const a = lib.albums.find((x) => x.id === view.album)
  if (!a) { showView('albums'); renderAlbums(); return }
  const total = a.tracks.reduce((s, t) => s + (t.duration || 0), 0)
  const first = a.tracks.find((t) => t.sampleRate) || a.tracks[0]
  const multiDisc = new Set(a.tracks.map((t) => t.disc)).size > 1
  const cur = current() ? trackId(current()) : null
  const info = [a.year, `${a.tracks.length} canciones`, total > 0 ? fmtTime(total) : null, quality(first), a.oneDrive ? 'OneDrive' : null]
  $('detailView').innerHTML = `
    <div class="dhead">
      <button class="back" id="backBtn" title="Volver">${I.back(22)}</button>
      ${thumbHTML(a)}
      <div class="meta">
        <div class="t ellipsis">${esc(a.title)}</div>
        <div class="s ellipsis">${esc(a.artist)}</div>
        <div class="x ellipsis">${esc(info.filter(Boolean).join(' · '))}</div>
      </div>
      ${a.oneDrive ? downloadButtonHTML(a) : ''}
      <button class="playAlbum" id="playAlbum" title="Reproducir">${I.playCircle(34)}</button>
    </div>
    <div class="scroll" id="tracks">
      ${a.tracks.map((t, i) => {
        const on = trackId(t) === cur
        const n = on ? `<span style="color:var(--accent)">${I.speaker(14, 'style="margin-left:auto"')}</span>` : (multiDisc ? `${t.disc}-${pad2(t.track)}` : pad2(t.track))
        return `<div class="trk ${on ? 'current' : ''}" data-i="${i}">
          <span class="n">${n}</span><span class="tt ellipsis">${esc(t.title)}</span>
          <span class="d">${t.duration > 0 ? fmtTime(t.duration) : ''}</span></div>`
      }).join('')}
    </div>`
  $('backBtn').onclick = () => { showView('albums'); renderAlbums() }
  $('playAlbum').onclick = () => playQueue(a.tracks, 0)
  $('tracks').onclick = (e) => {
    const el = e.target.closest('.trk')
    if (el) playQueue(a.tracks, Number(el.dataset.i))
  }
  const dl = $('dlBtn')
  if (dl) dl.onclick = () => {
    const saved = a.tracks.filter((t) => t.offline).length
    if (downloads[a.id]) return
    if (saved === a.tracks.length) {
      if (confirm('Este álbum está en el PC y se escucha sin internet.\n¿Borrarlo del PC? Seguirá disponible en OneDrive.')) api.removeDownload(a.id)
    } else {
      downloads[a.id] = { done: 0, total: a.tracks.length - saved }
      renderDetail()
      api.download(a.id)
    }
  }
}

function downloadButtonHTML(a) {
  const p = downloads[a.id]
  const saved = a.tracks.filter((t) => t.offline).length
  const complete = saved === a.tracks.length
  const title = p ? 'Descargando…' : complete ? 'Descargado: se escucha sin internet' :
    saved ? `Descargadas ${saved} de ${a.tracks.length}. Descargar el resto` : 'Descargar para escuchar sin internet'
  const inner = p ? `<span class="prog">${p.done}/${p.total}</span>` :
    `<span class="glyph">∫</span><span class="arrow" style="color:${complete ? 'var(--green)' : 'var(--red)'}">${complete ? I.check(11) : I.down(11)}</span>`
  return `<button class="dl" id="dlBtn" title="${title}">${inner}</button>`
}

api.onDownload((d) => {
  if (d.finished) delete downloads[d.album]
  else downloads[d.album] = { done: d.done, total: d.total }
  if (view.mode === 'detail' && view.album === d.album) renderDetail()
})

// ---------- OneDrive ----------
function openMenu(items, top = 38) {
  const m = $('menu')
  m.innerHTML = items.map((it, i) => it ? `<button data-i="${i}" class="${it[2] || ''}">${esc(it[0])}</button>` : '<hr>').join('')
  m.style.top = Math.max(8, Math.min(top, 260)) + 'px'
  m.hidden = false
  m.onclick = (e) => {
    const b = e.target.closest('button')
    if (!b) return
    m.hidden = true
    items[Number(b.dataset.i)][1]()
  }
}
document.addEventListener('click', (e) => {
  if (!e.target.closest('#menu') && !e.target.closest('#cloudBtn')) $('menu').hidden = true
})

async function connectOneDrive() {
  if (!lib.oneDrive.configured) return toast('Falta el Id. de cliente de OneDrive (secrets.json).')
  try {
    if (await api.signIn()) openPicker()
  } catch (e) { toast(e.message) }
}

$('cloudBtn').onclick = () => {
  const od = lib.oneDrive
  if (!$('menu').hidden) { $('menu').hidden = true; return }
  openMenu(od.signedIn ? [
    [od.folder ? `Carpeta: ${od.folder.name}` : 'Elegir carpeta de música', openPicker],
    ['Actualizar OneDrive', () => api.refreshOneDrive()],
    null,
    [`Cerrar sesión (${od.account || 'OneDrive'})`, () => api.signOut(), 'danger'],
  ] : [['Conectar OneDrive', connectOneDrive]])
}
$('emptyOneDrive').onclick = () => (lib.oneDrive.signedIn ? openPicker() : connectOneDrive())
$('addBtn').onclick = () => api.choose()
$('rescanBtn').onclick = () => api.rescan()

function openPicker() {
  view.picker = [{ id: null, name: 'OneDrive' }]
  showView('picker')
  renderPicker()
}
async function renderPicker() {
  const here = view.picker[view.picker.length - 1]
  const pv = $('pickerView')
  pv.innerHTML = `
    <div class="dhead">
      <button class="back" id="pickBack">${I.back(22)}</button>
      <div class="meta"><div class="t ellipsis">${esc(here.name)}</div></div>
    </div>
    <div class="scroll" id="pickList"><div class="note-line">Cargando…</div></div>
    <div class="pickfoot">${here.id
      ? `<button class="primary" id="pickUse">Usar "${esc(here.name)}" como biblioteca</button>`
      : '<div class="hint">Entra a tu carpeta de música y elígela abajo</div>'}</div>`
  $('pickBack').onclick = () => {
    if (view.picker.length > 1) { view.picker.pop(); renderPicker() } else { showView('albums'); renderAlbums() }
  }
  if (here.id) $('pickUse').onclick = () => {
    api.useFolder({ id: here.id, name: here.name })
    showView('albums')
    renderAlbums()
  }
  try {
    const items = (await api.children(here.id)).sort((a, b) => a.name.localeCompare(b.name, undefined, { numeric: true }))
    if (view.picker[view.picker.length - 1] !== here) return
    const folders = items.filter((i) => i.folder)
    const songs = items.filter((i) => i.audio).length
    $('pickList').innerHTML = (folders.length ? '' : `<div class="note-line">${songs ? songs + ' canciones en esta carpeta' : 'Sin subcarpetas'}</div>`) +
      folders.map((f, i) => `<div class="folder" data-i="${i}">${I.folder(20)}<span class="ellipsis">${esc(f.name)}</span></div>`).join('')
    $('pickList').onclick = (e) => {
      const el = e.target.closest('.folder')
      if (!el) return
      const f = folders[Number(el.dataset.i)]
      view.picker.push({ id: f.id, name: f.name })
      renderPicker()
    }
  } catch (e) {
    $('pickList').innerHTML = `<div class="note-line" style="color:#ff8a8a">${esc(e.message)}</div>`
  }
}

// ---------- arrastrar carpetas ----------
let dragDepth = 0
window.addEventListener('dragenter', (e) => { e.preventDefault(); dragDepth++; $('drop').hidden = false })
window.addEventListener('dragleave', () => { if (--dragDepth <= 0) { dragDepth = 0; $('drop').hidden = true } })
window.addEventListener('dragover', (e) => e.preventDefault())
window.addEventListener('drop', (e) => {
  e.preventDefault()
  dragDepth = 0
  $('drop').hidden = true
  const paths = [...e.dataTransfer.files].map((f) => api.pathFor(f)).filter(Boolean)
  if (paths.length) {
    api.add(paths)
    if (!libraryOpen) toggleLibrary(true)
  }
})

// ---------- datos desde el proceso principal ----------
api.onLibrary((data) => {
  lib = data
  // Actualiza la cola con datos nuevos (etiquetas leídas, descargas)
  player.queue = player.queue.map(freshTrack)
  renderNow()
})
api.onStatus((s) => {
  $('status').textContent = s
  $('cloudBtn').disabled = !!s
  $('rescanBtn').disabled = !!s
})
api.onError((msg) => toast(msg))

api.library().then((data) => { lib = data; renderNow() })
