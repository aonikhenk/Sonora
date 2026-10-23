import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@MainActor
final class UIState: ObservableObject {
    @Published var showLibrary = false
    @Published var selectedAlbumID: String?
    @Published var floating = UserDefaults.standard.bool(forKey: "floating") {
        didSet {
            UserDefaults.standard.set(floating, forKey: "floating")
            window?.level = floating ? .floating : .normal
        }
    }
    weak var window: NSWindow? {
        didSet { window?.level = floating ? .floating : .normal }
    }

    func toggleLibrary() {
        withAnimation(.easeInOut(duration: 0.2)) { showLibrary.toggle() }
    }

    func chooseFolders(into library: Library) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Agregar"
        if panel.runModal() == .OK {
            library.add(urls: panel.urls)
            showLibrary = true
        }
    }
}

@main
struct SonoraApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var library = Library()
    @StateObject private var player = Player()
    @StateObject private var ui = UIState()

    var body: some Scene {
        Window("Sonora", id: "main") {
            ContentView()
                .environmentObject(library)
                .environmentObject(player)
                .environmentObject(ui)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Agregar carpeta…") { ui.chooseFolders(into: library) }
                    .keyboardShortcut("o")
            }
            CommandMenu("Reproducción") {
                Button(player.isPlaying ? "Pausa" : "Reproducir") { player.togglePlay() }
                    .keyboardShortcut("p", modifiers: .command)
                Button("Siguiente") { player.next() }
                    .keyboardShortcut(.rightArrow, modifiers: .command)
                Button("Anterior") { player.previous() }
                    .keyboardShortcut(.leftArrow, modifiers: .command)
                Divider()
                Button(ui.showLibrary ? "Ocultar biblioteca" : "Mostrar biblioteca") { ui.toggleLibrary() }
                    .keyboardShortcut("l")
                Divider()
                Toggle("Frecuencia nativa (bit-perfect)", isOn: $player.nativeRate)
            }
        }
    }
}
