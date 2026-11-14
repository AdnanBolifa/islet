import IsletCore
import SwiftUI

@main
struct IsletApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var app

    var body: some Scene {
        Settings { EmptyView() } // everything lives in the menu bar and the island
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let stats = StatsModel()
    private let cleaner = CleanerModel()
    private let nowPlaying = NowPlayingModel()
    private let notifications = NotificationWatcher()
    private var island: IslandController!
    private var statusBar: StatusBarController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory) // no Dock icon, also under `swift run` (no Info.plist)
        Pref.register()

        island = IslandController(stats: stats, nowPlaying: nowPlaying)
        statusBar = StatusBarController(stats: stats, dashboard: DashboardView(stats: stats, cleaner: cleaner))

        stats.onTick = { [weak self] in
            guard let self else { return }
            statusBar.update()
            notifications.setEnabled(UserDefaults.standard.bool(forKey: Pref.notifications))
        }
        stats.onAlert = { [weak self] symbol, text in self?.island.show(Toast(symbol: symbol, title: text)) }
        cleaner.onFreed = { [weak self] bytes in
            self?.island.show(Toast(symbol: "sparkles", title: "Moved \(formatBytes(bytes)) to Trash", body: "Empty the Trash to free the space"))
        }
        notifications.onNotification = { [weak self] title, body in
            self?.island.show(Toast(symbol: "bell.fill", title: title, body: body))
        }

        applySettings()
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.applySettings() }
        }
        stats.start()

        if CommandLine.arguments.contains("--demo") { island.setExpanded(true) } // for screenshots
    }

    private func applySettings() {
        let defaults = UserDefaults.standard
        island.isVisible = defaults.bool(forKey: Pref.islandVisible)
        island.idleStats = defaults.bool(forKey: Pref.islandIdleStats)
        statusBar.applyVisibility()
        statusBar.update()
    }
}
