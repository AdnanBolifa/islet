import AppKit
import IsletCore
import SwiftUI

struct Toast: Equatable {
    var symbol: String
    var title: String
    var body: String?
}

/// Where the notch is and how big the island gets in each state.
struct IslandGeometry: Equatable {
    var screen = CGRect.zero
    var notch = CGSize(width: 190, height: 24)
    var hasNotch = false

    static let expandedWidth: CGFloat = 440
    var expandedHeight: CGFloat { notch.height + 150 }

    var panelFrame: CGRect {
        CGRect(x: screen.midX - Self.expandedWidth / 2, y: screen.maxY - expandedHeight,
               width: Self.expandedWidth, height: expandedHeight)
    }

    func pillSize(expanded: Bool, toast: Toast?, playing: Bool, idleStats: Bool) -> CGSize {
        if expanded { return CGSize(width: Self.expandedWidth, height: expandedHeight) }
        if let toast { return CGSize(width: min(max(notch.width + 200, 380), Self.expandedWidth), height: notch.height + (toast.body == nil ? 38 : 58)) }
        if playing { return CGSize(width: notch.width + 96, height: notch.height) }
        if idleStats { return CGSize(width: notch.width + 120, height: notch.height) }
        // Without a notch the idle island is invisible but still opens on hover.
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
    var geometry = IslandGeometry()
    var expanded = false
    var idleStats = true
    var toast: Toast?
}

/// Lets buttons in the island work on the first click even though Islet is never the active app.
private final class ClickThroughHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
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
        set {
            guard newValue != panel.isVisible else { return }
            newValue ? panel.orderFrontRegardless() : panel.orderOut(nil)
        }
    }

    var idleStats: Bool {
        get { state.idleStats }
        set { state.idleStats = newValue }
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
        let host = ClickThroughHostingView(rootView: IslandView(state: state, stats: stats, nowPlaying: nowPlaying))
        host.sizingOptions = [] // the panel keeps its own size; SwiftUI animates the pill inside it
        panel.contentView = host

        layout()
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.layout() }
        }
        // Mouse-moved monitors need no Accessibility permission (only key monitors do).
        let global = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] _ in
            MainActor.assumeIsolated { self?.trackMouse() }
        }
        let local = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] event in
            MainActor.assumeIsolated { self?.trackMouse() }
            return event
        }
        monitors = [global, local].compactMap { $0 }
    }

    func show(_ toast: Toast) {
        state.toast = toast
        toastTask?.cancel()
        toastTask = Task {
            try? await Task.sleep(for: .seconds(toast.body == nil ? 3 : 5))
            if !Task.isCancelled { state.toast = nil }
        }
    }

    func setExpanded(_ expanded: Bool) {
        guard state.expanded != expanded else { return }
        state.expanded = expanded
        panel.ignoresMouseEvents = !expanded
        if expanded { NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now) }
    }

    private func layout() {
        state.geometry = .current()
        panel.setFrame(state.geometry.panelFrame, display: true)
    }

    private func trackMouse() {
        let mouse = NSEvent.mouseLocation
        let geometry = state.geometry
        if state.expanded {
            if !geometry.panelFrame.insetBy(dx: -10, dy: -10).contains(mouse) { setExpanded(false) }
        } else {
            let collapsed = geometry.pillSize(expanded: false, toast: nil, playing: nowPlaying.isPlaying, idleStats: state.idleStats)
            if geometry.hoverRect(width: collapsed.width).contains(mouse) { setExpanded(true) }
        }
    }
}

// MARK: - Views

struct IslandView: View {
    let state: IslandState
    let stats: StatsModel
    let nowPlaying: NowPlayingModel

    var body: some View {
        let geometry = state.geometry
        let size = geometry.pillSize(expanded: state.expanded, toast: state.toast,
                                     playing: nowPlaying.isPlaying, idleStats: state.idleStats)
        let radius: CGFloat = state.expanded ? 32 : state.toast != nil ? 22 : 12

        ZStack(alignment: .top) {
            UnevenRoundedRectangle(bottomLeadingRadius: radius, bottomTrailingRadius: radius, style: .continuous)
                .fill(.black)
                .shadow(color: .black.opacity(0.35), radius: state.expanded ? 12 : 0, y: state.expanded ? 6 : 0)
            content(geometry)
                .foregroundStyle(.white)
        }
        .frame(width: size.width, height: size.height)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(.spring(response: 0.42, dampingFraction: 0.78), value: size)
        .animation(.easeInOut(duration: 0.2), value: state.expanded)
        .environment(\.colorScheme, .dark)
    }

    @ViewBuilder
    private func content(_ geometry: IslandGeometry) -> some View {
        if state.expanded {
            ExpandedIsland(stats: stats, nowPlaying: nowPlaying)
                .padding(.top, geometry.notch.height + 10)
                .padding(.horizontal, 22)
                .transition(.opacity.combined(with: .scale(scale: 0.92, anchor: .top)))
        } else if let toast = state.toast {
            ToastView(toast: toast)
                .padding(.top, geometry.notch.height + 8)
                .padding(.horizontal, 20)
                .transition(.opacity)
        } else if nowPlaying.isPlaying {
            Wings(notchWidth: geometry.notch.width, height: geometry.notch.height) {
                Artwork(image: nowPlaying.artwork, size: 18, corner: 5)
            } right: {
                EqualizerBars()
            }
            .transition(.opacity)
        } else if state.idleStats {
            Wings(notchWidth: geometry.notch.width, height: geometry.notch.height) {
                WingStat(symbol: "cpu", text: percentText(stats.cpu), level: stats.cpu)
            } right: {
                WingStat(symbol: "thermometer.medium", text: stats.temperatureText, level: stats.heatLevel)
            }
            .transition(.opacity)
        }
    }
}

/// Content placed on both sides of the physical notch.
private struct Wings<Left: View, Right: View>: View {
    let notchWidth: CGFloat
    let height: CGFloat
    @ViewBuilder let left: Left
    @ViewBuilder let right: Right

    var body: some View {
        HStack(spacing: 0) {
            left.frame(maxWidth: .infinity, alignment: .leading)
            Color.clear.frame(width: notchWidth)
            right.frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, 14)
        .frame(height: height)
    }
}

private struct WingStat: View {
    let symbol: String
    let text: String
    let level: Double

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: symbol).font(.system(size: 10, weight: .semibold)).foregroundStyle(.white.opacity(0.55))
            Text(text)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(level > 0.85 ? .red : level > 0.6 ? .orange : .white)
        }
        // No number animation here: it would redraw the always-on wings every 2 s and cost idle CPU.
    }
}

private struct ExpandedIsland: View {
    let stats: StatsModel
    let nowPlaying: NowPlayingModel

    var body: some View {
        VStack(spacing: 14) {
            HStack(spacing: 12) {
                Artwork(image: nowPlaying.artwork, size: 50, corner: 12)
                VStack(alignment: .leading, spacing: 3) {
                    Text(nowPlaying.title ?? "Nothing playing")
                        .font(.system(size: 14, weight: .semibold))
                        .lineLimit(1)
                    if let browser = nowPlaying.browserNeedsJavaScript {
                        Text("For controls: \(browser.shortName) › Developer › Allow JavaScript from Apple Events")
                            .font(.system(size: 11))
                            .foregroundStyle(.orange.opacity(0.9))
                            .lineLimit(2)
                    } else {
                        Text(nowPlaying.hasSource ? nowPlaying.subtitle : "Play something in Music, Spotify or YouTube")
                            .font(.system(size: 12))
                            .foregroundStyle(.white.opacity(0.55))
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                if nowPlaying.hasSource && nowPlaying.browserNeedsJavaScript == nil {
                    HStack(spacing: 16) {
                        ControlButton(symbol: "backward.fill", size: 14) { nowPlaying.previous() }
                        ControlButton(symbol: nowPlaying.isPlaying ? "pause.fill" : "play.fill", size: 22) { nowPlaying.playPause() }
                        ControlButton(symbol: "forward.fill", size: 14) { nowPlaying.next() }
                    }
                }
            }

            HStack(spacing: 0) {
                Ring(label: "CPU", text: percentText(stats.cpu), value: stats.cpu)
                Spacer()
                Ring(label: "Memory", text: percentText(stats.memory.fraction), value: stats.memory.fraction)
                Spacer()
                Ring(label: "Swap", text: stats.swapText, value: stats.swapLevel)
                Spacer()
                Ring(label: "Temp", text: stats.temperatureText, value: stats.heatLevel)
                Spacer()
                Ring(label: "Disk", text: compactBytes(stats.disk.free), value: stats.disk.usedFraction)
                Spacer()
                VStack(alignment: .leading, spacing: 4) {
                    Label(rateText(stats.download), systemImage: "arrow.down")
                    Label(rateText(stats.upload), systemImage: "arrow.up")
                }
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .labelStyle(TightLabel())
            }
        }
    }
}

private struct TightLabel: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 3) {
            configuration.icon.foregroundStyle(.white.opacity(0.5))
            configuration.title
        }
    }
}

private struct Ring: View {
    let label: String
    let text: String
    let value: Double

    var body: some View {
        VStack(spacing: 5) {
            ZStack {
                Circle().stroke(.white.opacity(0.12), lineWidth: 4)
                Circle()
                    .trim(from: 0, to: min(max(value, 0.02), 1))
                    .stroke(levelColor(value), style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text(text)
                    .font(.system(size: 9.5, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .minimumScaleFactor(0.7)
                    .padding(4)
            }
            .frame(width: 40, height: 40)
            .animation(.easeOut(duration: 0.4), value: value)
            Text(label).font(.system(size: 9.5, weight: .medium)).foregroundStyle(.white.opacity(0.5))
        }
    }
}

private struct ControlButton: View {
    let symbol: String
    let size: CGFloat
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 30, height: 30)
                .background(.white.opacity(hovering ? 0.12 : 0), in: Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

private struct Artwork: View {
    let image: NSImage?
    let size: CGFloat
    let corner: CGFloat

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: "music.note")
                    .font(.system(size: size * 0.45, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.7))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(LinearGradient(colors: [.pink.opacity(0.8), .purple.opacity(0.8)], startPoint: .topLeading, endPoint: .bottomTrailing))
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
    }
}

private struct ToastView: View {
    let toast: Toast

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: toast.symbol)
                .font(.system(size: 14, weight: .semibold))
                .frame(width: 26, height: 26)
                .background(.white.opacity(0.14), in: Circle())
            VStack(alignment: .leading, spacing: 1) {
                Text(toast.title).font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
                if let body = toast.body {
                    Text(body).font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
    }
}

/// Small animated equalizer shown while music plays.
private struct EqualizerBars: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 20)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 2) {
                ForEach(0..<4, id: \.self) { i in
                    Capsule()
                        .fill(LinearGradient(colors: [.green, .mint], startPoint: .bottom, endPoint: .top))
                        .frame(width: 2.5, height: 4 + 9 * abs(sin(t * 3.1 + Double(i) * 0.95)))
                }
            }
            .frame(height: 13)
        }
    }
}
