import IsletCore
import SwiftUI

@main
struct IsletApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var app

    var body: some Scene {
        MenuBarExtra("Islet", systemImage: "capsule.fill") {
            DashboardView(stats: app.stats, cleaner: app.cleaner) { app.island?.isVisible = $0 }
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let stats = StatsModel()
    let cleaner = CleanerModel()
    let nowPlaying = NowPlayingModel()
    private(set) var island: IslandController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory) // no Dock icon, also under `swift run` (no Info.plist)

        let island = IslandController(stats: stats, nowPlaying: nowPlaying)
        island.isVisible = UserDefaults.standard.object(forKey: "showIsland") as? Bool ?? true
        stats.onAlert = { [weak island] icon, text in island?.show(toast: icon, text) }
        cleaner.onFreed = { [weak island] bytes in island?.show(toast: "sparkles", "Moved \(formatBytes(bytes)) to Trash") }
        self.island = island

        stats.start()
    }
}
