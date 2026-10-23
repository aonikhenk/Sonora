// Puente seguro entre la interfaz y el proceso principal
const { contextBridge, ipcRenderer, webUtils } = require('electron')

const on = (channel) => (fn) => ipcRenderer.on(channel, (_e, data) => fn(data))

contextBridge.exposeInMainWorld('sonora', {
  library: () => ipcRenderer.invoke('library:get'),
  add: (paths) => ipcRenderer.invoke('library:add', paths),
  choose: () => ipcRenderer.invoke('library:choose'),
  rescan: () => ipcRenderer.invoke('library:rescan'),
  remove: (albumId) => ipcRenderer.invoke('library:remove', albumId),
  reveal: (file) => ipcRenderer.invoke('library:reveal', file),
  source: (track) => ipcRenderer.invoke('track:source', track),
  pathFor: (file) => webUtils.getPathForFile(file),

  signIn: () => ipcRenderer.invoke('onedrive:signin'),
  signOut: () => ipcRenderer.invoke('onedrive:signout'),
  children: (id) => ipcRenderer.invoke('onedrive:children', id),
  useFolder: (folder) => ipcRenderer.invoke('onedrive:use', folder),
  refreshOneDrive: () => ipcRenderer.invoke('onedrive:refresh'),

  download: (albumId) => ipcRenderer.invoke('offline:download', albumId),
  removeDownload: (albumId) => ipcRenderer.invoke('offline:remove', albumId),

  setLibraryOpen: (open) => ipcRenderer.invoke('window:library', open),
  setFloating: (on) => ipcRenderer.invoke('window:floating', on),
  settings: () => ipcRenderer.invoke('window:settings'),
  minimize: () => ipcRenderer.invoke('window:minimize'),
  close: () => ipcRenderer.invoke('window:close'),

  onLibrary: on('library'),
  onStatus: on('status'),
  onError: on('error'),
  onDownload: on('download'),
})
