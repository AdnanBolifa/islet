import AppKit
import IsletCore
import SwiftUI

/// Where the notch is and how big the island gets in each state.
struct IslandGeometry: Equatable {
    var screen = CGRect.zero
    var notch = CGSize(width: 190, height: 24)
    var hasNotch = false

    static let expandedWidth: CGFloat = 400
    var expandedHeight: CGFloat { notch.height + 112 }

    var panelFrame: CGRect {
        CGRect(x: screen.midX - Self.expandedWidth / 2, y: screen.maxY - expandedHeight,
               width: Self.expandedWidth, height: expandedHeight)
    }

    func pillSize(expanded: Bool, toast: Bool, playing: Bool) -> CGSize {
        if expanded { return CGSize(width: Self.expandedWidth, height: expandedHeight) }
        if toast { return CGSize(width: max(notch.width + 140, 320), height: notch.height + 36) }
        if playing { return CGSize(width: notch.width + 84, height: notch.height) }
        // Without a notch the idle island is invisible but still expands on hover.
        return hasNotch ? notch : CGSize(width: notch.width, height: 0)
    }

    /// The strip at the top of the screen that opens the island on hover.
    func hoverRect(width: CGFloat) -> CGRect {
        CGRect(x: screen.midX - width / 2, y: screen.maxY - notch.height, width: width, height: notch.height + 2)
    }

    @MainActor static func current() -> IslandGeometry {
        guard let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.main else { return .init() }
        var geometry = IslandGeometry(screen: screen.frame)
        if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea, screen.safeAreaInsets.top > 0 {
            geometry.hasNotch = true
            geometry.notch = CGSize(width: right.minX - left.maxX, height: screen.safeAreaInsets.top)
        } else {
            geometry.notch.height = NSApp.mainMenu?.menuBarHeight ?? 24
        }
        return geometry
    }
}

@MainActor @Observable
final class IslandState {
    struct Toast: Equatable {
        var icon: String
        var text: String
    }

    var geometry = IslandGeometry()
    var expanded = false
    var toast: Toast?
}

@MainActor
final class IslandController {
    private let state = IslandState()
    private let nowPlaying: NowPlayingModel
    private let panel: NSPanel
    private var monitors: [Any] = []
    private var toastTask: Task<Void, Never>?

    var isVisible: Bool {
        get { panel.isVisible }
        set { newValue ? panel.orderFrontRegardless() : panel.orderOut(nil) }
    }

    init(stats: StatsModel, nowPlaying: NowPlayingModel) {
        self.nowPlaying = nowPlaying
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true // clicks pass through until the island is open
        panel.contentView = NSHostingView(rootView: IslandView(state: state, stats: stats, nowPlaying: nowPlaying))

        layout()
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.layout() }
        }
        // Mouse-moved monitors need no Accessibility permission (only key monitors do).
        let global = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] _ in
            MainActor.assumeIsolated { self?.trackMouse() }
        }
        let local = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { [weak self] event in
            MainActor.assumeIsolated { self?.trackMouse() }
            return event
        }
        monitors = [global, local].compactMap { $0 }
    }

    func show(toast icon: String, _ text: String) {
        state.toast = .init(icon: icon, text: text)
        toastTask?.cancel()
        toastTask = Task {
            try? await Task.sleep(for: .seconds(3))
            if !Task.isCancelled { state.toast = nil }
        }
    }

    private func layout() {
        state.geometry = .current()
        panel.setFrame(state.geometry.panelFrame, display: true)
    }

    private func trackMouse() {
        let mouse = NSEvent.mouseLocation
        let geometry = state.geometry
        if state.expanded {
            if !geometry.panelFrame.insetBy(dx: -8, dy: -8).contains(mouse) { setExpanded(false) }
        } else {
            let idle = geometry.pillSize(expanded: false, toast: false, playing: nowPlaying.isPlaying)
            if geometry.hoverRect(width: idle.width).contains(mouse) { setExpanded(true) }
        }
    }

    private func setExpanded(_ expanded: Bool) {
        guard state.expanded != expanded else { return }
        state.expanded = expanded
        panel.ignoresMouseEvents = !expanded
    }
}

struct IslandView: View {
    let state: IslandState
    let stats: StatsModel
    let nowPlaying: NowPlayingModel

    var body: some View {
        let geometry = state.geometry
        let size = geometry.pillSize(expanded: state.expanded, toast: state.toast != nil, playing: nowPlaying.isPlaying)
        let radius: CGFloat = state.expanded ? 26 : 12

        ZStack(alignment: .top) {
            UnevenRoundedRectangle(bottomLeadingRadius: radius, bottomTrailingRadius: radius, style: .continuous)
                .fill(.black)
            content(notchHeight: geometry.notch.height)
                .foregroundStyle(.white)
        }
        .frame(width: size.width, height: size.height)
        .clipped()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(.spring(response: 0.38, dampingFraction: 0.8), value: size)
    }

    @ViewBuilder
    private func content(notchHeight: CGFloat) -> some View {
        if state.expanded {
            VStack(spacing: 14) {
                if let title = nowPlaying.title {
                    HStack(spacing: 10) {
                        Image(systemName: "music.note")
                            .font(.system(size: 15, weight: .semibold))
                            .frame(width: 32, height: 32)
                            .background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                        VStack(alignment: .leading, spacing: 1) {
                            Text(title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                            Text(nowPlaying.artist ?? "").font(.system(size: 11)).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
                        }
                        Spacer()
                        if nowPlaying.isPlaying { Bars() }
                    }
                }
                HStack {
                    Chip(icon: "cpu", value: stats.cpu.formatted(.percent.precision(.fractionLength(0))))
                    Spacer()
                    Chip(icon: "memorychip", value: formatBytes(stats.memory.used, style: .memory))
                    Spacer()
                    Chip(icon: "internaldrive", value: formatBytes(stats.disk.free))
                    Spacer()
                    Chip(icon: "thermometer.medium", value: stats.thermal.label)
                }
            }
            .padding(.top, notchHeight + 10)
            .padding(.horizontal, 22)
            .transition(.opacity)
        } else if let toast = state.toast {
            HStack(spacing: 8) {
                Image(systemName: toast.icon)
                Text(toast.text).lineLimit(1)
            }
            .font(.system(size: 12, weight: .medium))
            .padding(.top, notchHeight + 8)
            .transition(.opacity)
        } else if nowPlaying.isPlaying {
            HStack {
                Image(systemName: "music.note").font(.system(size: 11, weight: .bold))
                Spacer()
                Bars()
            }
            .padding(.horizontal, 14)
            .frame(height: notchHeight)
            .transition(.opacity)
        }
    }
}

private struct Chip: View {
    let icon: String
    let value: String

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: icon).foregroundStyle(.white.opacity(0.55))
            Text(value).monospacedDigit()
        }
        .font(.system(size: 11, weight: .medium))
    }
}

/// Small animated equalizer shown while music plays.
private struct Bars: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 20)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: 2) {
                ForEach(0..<4, id: \.self) { i in
                    Capsule()
                        .fill(.green)
                        .frame(width: 2.5, height: 4 + 8 * abs(sin(t * 3.2 + Double(i) * 0.9)))
                }
            }
            .frame(height: 12)
        }
    }
}
