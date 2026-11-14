import AppKit
import IsletCore
import Observation

@MainActor @Observable
final class StatsModel {
    private(set) var cpu = 0.0
    private(set) var memory = MemoryInfo.current()
    private(set) var disk = DiskInfo.current()
    private(set) var thermal = ProcessInfo.processInfo.thermalState

    @ObservationIgnored var onAlert: ((String, String) -> Void)?
    @ObservationIgnored private var sampler = CPUSampler()
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var memoryAlerted = false
    @ObservationIgnored private var thermalAlerted = false

    func start() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    private func refresh() {
        cpu = sampler.sample()
        memory = .current()
        disk = .current()
        thermal = ProcessInfo.processInfo.thermalState

        // Alert once each time a threshold is crossed, not every tick.
        let memoryHigh = memory.fraction > 0.92
        if memoryHigh && !memoryAlerted {
            onAlert?("memorychip", "Memory almost full · \(formatBytes(memory.swapUsed, style: .memory)) swap")
        }
        memoryAlerted = memoryHigh

        let hot = thermal == .serious || thermal == .critical
        if hot && !thermalAlerted { onAlert?("thermometer.high", "Your Mac is running hot") }
        thermalAlerted = hot
    }
}

@MainActor @Observable
final class NowPlayingModel {
    private(set) var title: String?
    private(set) var artist: String?
    private(set) var isPlaying = false

    init() {
        // Music and Spotify broadcast every track/state change publicly; no private API needed.
        for name in ["com.apple.Music.playerInfo", "com.spotify.client.PlaybackStateChanged"] {
            DistributedNotificationCenter.default().addObserver(forName: .init(name), object: nil, queue: .main) { [weak self] note in
                let info = note.userInfo ?? [:]
                MainActor.assumeIsolated { self?.update(info) }
            }
        }
    }

    private func update(_ info: [AnyHashable: Any]) {
        let state = info["Player State"] as? String
        isPlaying = state == "Playing"
        title = state == "Stopped" ? nil : info["Name"] as? String
        artist = state == "Stopped" ? nil : info["Artist"] as? String
    }
}

@MainActor @Observable
final class CleanerModel {
    private(set) var folders: [URL] = []
    private(set) var results: [Artifact] = []
    private(set) var scanning = false
    private(set) var hasScanned = false
    private(set) var lastFreed: Int64?
    var selected = Set<URL>()

    @ObservationIgnored var onFreed: ((Int64) -> Void)?
    @ObservationIgnored private let bookmarksKey = "folderBookmarks"

    var selectedSize: Int64 { results.filter { selected.contains($0.url) }.reduce(0) { $0 + $1.size } }

    init() {
        let bookmarks = UserDefaults.standard.array(forKey: bookmarksKey) as? [Data] ?? []
        folders = bookmarks.compactMap { data in
            var stale = false
            guard let url = try? URL(resolvingBookmarkData: data, options: .withSecurityScope, bookmarkDataIsStale: &stale) else { return nil }
            // shortcut: sandbox access is held for the app's lifetime; fine for a few folders, revisit if users add dozens.
            _ = url.startAccessingSecurityScopedResource()
            return url
        }
        save() // refreshes stale bookmarks
    }

    func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        panel.message = "Choose folders that contain your projects."
        NSApp.activate()
        guard panel.runModal() == .OK else { return }
        for url in panel.urls where !folders.contains(url) {
            _ = url.startAccessingSecurityScopedResource()
            folders.append(url)
        }
        save()
    }

    func removeFolder(_ url: URL) {
        url.stopAccessingSecurityScopedResource()
        folders.removeAll { $0 == url }
        results.removeAll { $0.url.path.hasPrefix(url.path) }
        save()
    }

    func scan() async {
        scanning = true
        lastFreed = nil
        let roots = folders
        let found = await Task.detached(priority: .userInitiated) { Cleaner.scan(roots) }.value
        results = found
        selected = Set(found.map(\.url))
        scanning = false
        hasScanned = true
    }

    func trashSelected() {
        let outcome = Cleaner.trash(results.filter { selected.contains($0.url) })
        results.removeAll { outcome.trashed.contains($0.url) }
        selected.subtract(outcome.trashed)
        lastFreed = outcome.freed
        if outcome.freed > 0 { onFreed?(outcome.freed) }
    }

    private func save() {
        let bookmarks = folders.compactMap {
            try? $0.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
        }
        UserDefaults.standard.set(bookmarks, forKey: bookmarksKey)
    }
}

extension ProcessInfo.ThermalState {
    var label: String {
        switch self {
        case .nominal: "Normal"
        case .fair: "Warm"
        case .serious: "Hot"
        case .critical: "Critical"
        @unknown default: "Unknown"
        }
    }

    var level: Double {
        switch self {
        case .nominal: 0.15
        case .fair: 0.5
        case .serious: 0.8
        default: 1
        }
    }
}
