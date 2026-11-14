import AppKit
import ApplicationServices
import IsletCore
import Observation
import SwiftUI

// MARK: - Preferences

enum Metric: String, CaseIterable {
    case cpu, memory, swap, temperature, network, disk

    var title: String {
        switch self {
        case .cpu: "CPU"
        case .memory: "Memory"
        case .swap: "Swap"
        case .temperature: "Temperature"
        case .network: "Network"
        case .disk: "Disk"
        }
    }

    var symbol: String {
        switch self {
        case .cpu: "cpu"
        case .memory: "memorychip"
        case .swap: "arrow.triangle.swap"
        case .temperature: "thermometer.medium"
        case .network: "arrow.up.arrow.down"
        case .disk: "internaldrive"
        }
    }
}

enum Pref {
    static let islandVisible = "island.visible"
    static let islandIdleStats = "island.idleStats"
    static let notifications = "island.notifications"
    static func menu(_ metric: Metric) -> String { "menu.\(metric.rawValue)" }

    static func register() {
        var defaults: [String: Any] = [islandVisible: true, islandIdleStats: true, notifications: false]
        for metric in Metric.allCases { defaults[menu(metric)] = metric != .disk && metric != .swap }
        UserDefaults.standard.register(defaults: defaults)
    }
}

// MARK: - Formatting

func percentText(_ value: Double) -> String { "\(Int((value * 100).rounded()))%" }

func rateText(_ bytesPerSecond: Double) -> String {
    let kilobytes = bytesPerSecond / 1024
    if kilobytes < 1000 { return "\(Int(kilobytes))K" }
    let megabytes = kilobytes / 1024
    return megabytes < 10 ? String(format: "%.1fM", megabytes) : "\(Int(megabytes))M"
}

/// "92G" / "3.4G": short enough for a ring or the menu bar.
func compactBytes(_ bytes: Int64) -> String {
    let gigabytes = Double(bytes) / 1e9
    return gigabytes < 10 ? String(format: "%.1fG", gigabytes) : "\(Int(gigabytes.rounded()))G"
}

func levelColor(_ value: Double) -> Color { value < 0.6 ? .green : value < 0.85 ? .orange : .red }

// MARK: - System stats

@MainActor @Observable
final class StatsModel {
    private(set) var cpu = 0.0
    private(set) var memory = MemoryInfo.current()
    private(set) var disk = DiskInfo.current()
    private(set) var thermal = ProcessInfo.processInfo.thermalState
    private(set) var temperature: Double?
    private(set) var download = 0.0
    private(set) var upload = 0.0

    @ObservationIgnored var onTick: (() -> Void)?
    @ObservationIgnored var onAlert: ((String, String) -> Void)?
    @ObservationIgnored private var cpuSampler = CPUSampler()
    @ObservationIgnored private var networkSampler = NetworkSampler()
    @ObservationIgnored private let sensor = TemperatureReader()
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var memoryAlerted = false
    @ObservationIgnored private var heatAlerted = false

    /// Temperature as 0...1 for gauges (100 °C = full); falls back to the thermal state on Intel.
    var heatLevel: Double { temperature.map { $0 / 100 } ?? thermal.level }
    /// Swap compared to RAM size: 0.5 means swap holds half your RAM's worth, which you will feel.
    var swapLevel: Double { Double(memory.swapUsed) / Double(max(memory.total, 1)) }
    var swapText: String { compactBytes(Int64(memory.swapUsed)) }

    var temperatureText: String { temperature.map { "\(Int($0.rounded()))°" } ?? thermal.label }

    func start() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    private func refresh() {
        cpu = cpuSampler.sample()
        memory = .current()
        disk = .current()
        thermal = ProcessInfo.processInfo.thermalState
        temperature = sensor.cpuCelsius()
        (download, upload) = networkSampler.sample()

        // Alert once each time a threshold is crossed, not on every tick.
        let memoryHigh = memory.fraction > 0.92
        if memoryHigh && !memoryAlerted {
            onAlert?("memorychip", "Memory almost full · \(formatBytes(memory.swapUsed, style: .memory)) swap")
        }
        memoryAlerted = memoryHigh

        let hot = thermal == .serious || thermal == .critical || (temperature ?? 0) > 95
        if hot && !heatAlerted { onAlert?("thermometer.high", "Your Mac is running hot · \(temperatureText)") }
        heatAlerted = hot

        onTick?()
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

// MARK: - Other apps' notifications

/// Mirrors notification banners into the island by watching Notification Center through Accessibility.
@MainActor
final class NotificationWatcher {
    var onNotification: ((String, String?) -> Void)?
    private var observer: AXObserver?
    private var lastText = ""

    static var isTrusted: Bool { AXIsProcessTrusted() }

    static func requestAccess() {
        let prompt = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([prompt: true] as CFDictionary)
    }

    /// Idempotent; called every tick so it starts as soon as access is granted.
    func setEnabled(_ enabled: Bool) {
        if !enabled {
            if let observer { CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode) }
            observer = nil
            return
        }
        guard observer == nil, Self.isTrusted,
              let center = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.notificationcenterui").first
        else { return }

        var created: AXObserver?
        let callback: AXObserverCallback = { _, element, _, context in
            guard let context else { return }
            let watcher = Unmanaged<NotificationWatcher>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { watcher.bannerAppeared(element) }
        }
        guard AXObserverCreate(center.processIdentifier, callback, &created) == .success, let created else { return }
        let app = AXUIElementCreateApplication(center.processIdentifier)
        let context = Unmanaged.passUnretained(self).toOpaque()
        AXObserverAddNotification(created, app, kAXWindowCreatedNotification as CFString, context)
        AXObserverAddNotification(created, app, kAXCreatedNotification as CFString, context)
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(created), .defaultMode)
        observer = created
    }

    private func bannerAppeared(_ element: AXUIElement) {
        // The banner's text fills in a moment after its window appears.
        Task {
            try? await Task.sleep(for: .milliseconds(250))
            var texts: [String] = []
            Self.collectText(element, into: &texts, depth: 0)
            let joined = texts.joined(separator: "\n")
            guard !texts.isEmpty, joined != lastText else { return }
            lastText = joined
            onNotification?(texts[0], texts.dropFirst().joined(separator: " · ").nilIfEmpty)
        }
    }

    private static func collectText(_ element: AXUIElement, into texts: inout [String], depth: Int) {
        guard depth < 10, texts.count < 4 else { return }
        if let role = attribute(element, kAXRoleAttribute) as? String, role == kAXStaticTextRole,
           let value = attribute(element, kAXValueAttribute) as? String, !value.isEmpty {
            texts.append(value)
        }
        for child in attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? [] {
            collectText(child, into: &texts, depth: depth + 1)
        }
    }

    private static func attribute(_ element: AXUIElement, _ name: String) -> AnyObject? {
        var value: AnyObject?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

// MARK: - Cleanup

@MainActor @Observable
final class CleanerModel {
    private(set) var folders: [URL] = []
    private(set) var results: [Artifact] = []
    private(set) var scanning = false
    private(set) var hasScanned = false
    private(set) var lastFreed: Int64?
    var selected = Set<URL>()

    @ObservationIgnored var onFreed: ((Int64) -> Void)?
    @ObservationIgnored private let foldersKey = "cleaner.folders"

    var selectedSize: Int64 { results.filter { selected.contains($0.url) }.reduce(0) { $0 + $1.size } }

    init() {
        folders = (UserDefaults.standard.stringArray(forKey: foldersKey) ?? []).map { URL(fileURLWithPath: $0) }
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
        folders += panel.urls.filter { !folders.contains($0) }
        save()
    }

    func removeFolder(_ url: URL) {
        folders.removeAll { $0 == url }
        results.removeAll { $0.url.path.hasPrefix(url.path + "/") }
        save()
    }

    func scan() async {
        scanning = true
        lastFreed = nil
        let roots = folders
        let found = await Task.detached(priority: .userInitiated) {
            (Cleaner.scan(roots) + Cleaner.scanDeveloperCaches()).sorted { $0.size > $1.size }
        }.value
        results = found
        selected = Set(found.filter { !$0.isCache }.map(\.url))
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
        UserDefaults.standard.set(folders.map(\.path), forKey: foldersKey)
    }
}
