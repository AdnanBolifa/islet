import AppKit
import IsletCore
import SwiftUI

/// One menu bar item per metric, in a row like Battery and Wi-Fi. Any of them opens the dashboard.
@MainActor
final class StatusBarController: NSObject {
    private let stats: StatsModel
    private let popover = NSPopover()
    private let mainItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private var metricItems: [(Metric, NSStatusItem)] = []

    init(stats: StatsModel, dashboard: some View) {
        self.stats = stats
        super.init()

        let host = NSHostingController(rootView: dashboard)
        host.sizingOptions = .preferredContentSize
        popover.contentViewController = host
        popover.behavior = .transient

        configure(mainItem, name: "islet")
        mainItem.button?.image = NSImage(systemSymbolName: "capsule.fill", accessibilityDescription: "Islet")?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .medium))
        // New items appear to the left of older ones, so create them reversed to read CPU, Memory, … left to right.
        for metric in Metric.allCases.reversed() {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            configure(item, name: metric.rawValue)
            item.button?.setAccessibilityLabel(metric.title)
            metricItems.append((metric, item))
        }
        applyVisibility()
        update()
    }

    func applyVisibility() {
        for (metric, item) in metricItems {
            item.isVisible = UserDefaults.standard.bool(forKey: Pref.menu(metric))
        }
    }

    func update() {
        for (metric, item) in metricItems where item.isVisible {
            item.button?.image = image(for: metric)
            item.button?.toolTip = metric.title
        }
    }

    private func image(for metric: Metric) -> NSImage {
        switch metric {
        case .cpu: stacked("CPU", percentText(stats.cpu), widest: "100%")
        case .memory: stacked("MEM", percentText(stats.memory.fraction), widest: "100%")
        case .temperature: stacked("TEMP", stats.temperatureText, widest: "100°")
        case .network: stacked("↑" + rateText(stats.upload), "↓" + rateText(stats.download), widest: "↓9.9M", even: true)
        case .disk: stacked("FREE", compactBytes(stats.disk.free), widest: "999G")
        }
    }

    private static let labelFont = NSFont.systemFont(ofSize: 7.5, weight: .semibold)
    private static let valueFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
    private static let pairFont = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .semibold)

    /// A small label above its value, like Stats does: about half the width of icon + text,
    /// which matters on notched Macs where macOS hides items that don't fit.
    /// `widest` fixes the width so items don't jiggle as numbers change.
    private func stacked(_ top: String, _ bottom: String, widest: String, even: Bool = false) -> NSImage {
        let topFont = even ? Self.pairFont : Self.labelFont
        let bottomFont = even ? Self.pairFont : Self.valueFont
        let upper = NSAttributedString(string: top, attributes: [.font: topFont])
        let lower = NSAttributedString(string: bottom, attributes: [.font: bottomFont])
        let width = ceil([upper.size().width, lower.size().width,
                          NSAttributedString(string: widest, attributes: [.font: bottomFont]).size().width].max()!)
        let image = NSImage(size: NSSize(width: width, height: 22), flipped: false) { _ in
            upper.draw(at: NSPoint(x: (width - upper.size().width) / 2, y: even ? 10.5 : 12.5))
            lower.draw(at: NSPoint(x: (width - lower.size().width) / 2, y: even ? 0 : -0.5))
            return true
        }
        image.isTemplate = true // follows the menu bar's light/dark appearance
        return image
    }

    private func configure(_ item: NSStatusItem, name: String) {
        item.autosaveName = "islet.\(name)" // remembers ⌘-drag positions
        item.button?.target = self
        item.button?.action = #selector(togglePopover(_:))
    }

    @objc private func togglePopover(_ sender: NSStatusBarButton) {
        if popover.isShown {
            popover.performClose(nil)
        } else {
            NSApp.activate()
            popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
        }
    }
}
