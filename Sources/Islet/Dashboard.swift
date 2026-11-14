import IsletCore
import ServiceManagement
import SwiftUI

struct DashboardView: View {
    enum Tab: String, CaseIterable { case overview = "Overview", clean = "Clean", settings = "Settings" }

    let stats: StatsModel
    let cleaner: CleanerModel
    @State private var tab = Tab.overview

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Islet").font(.system(size: 15, weight: .semibold))
                Spacer()
                Picker("Section", selection: $tab) {
                    ForEach(Tab.allCases, id: \.self) { Text($0.rawValue) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 230)
            }

            switch tab {
            case .overview: OverviewView(stats: stats)
            case .clean: CleanerView(model: cleaner)
            case .settings: SettingsView()
            }

            Divider()

            HStack {
                Text("Islet \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev")")
                    .foregroundStyle(.tertiary)
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
            }
            .font(.callout)
        }
        .padding(16)
        .frame(width: 360)
    }
}

// MARK: - Overview

private struct OverviewView: View {
    let stats: StatsModel

    var body: some View {
        let memory = stats.memory
        let disk = stats.disk
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible())], spacing: 10) {
            StatTile(icon: "cpu", title: "CPU", value: percentText(stats.cpu),
                     detail: "\(ProcessInfo.processInfo.activeProcessorCount) cores", progress: stats.cpu)
            StatTile(icon: "memorychip", title: "Memory", value: formatBytes(memory.used, style: .memory),
                     detail: "of \(formatBytes(memory.total, style: .memory)) · \(formatBytes(memory.swapUsed, style: .memory)) swap",
                     progress: memory.fraction)
            StatTile(icon: "thermometer.medium", title: "Temperature",
                     value: stats.temperature.map { "\(Int($0.rounded())) °C" } ?? stats.thermal.label,
                     detail: "CPU · \(stats.thermal.label.lowercased())", progress: stats.heatLevel)
            StatTile(icon: "internaldrive", title: "Disk", value: formatBytes(disk.free),
                     detail: "free of \(formatBytes(disk.total))", progress: disk.usedFraction)
        }

        HStack {
            Label("Network", systemImage: "network").foregroundStyle(.secondary)
            Spacer()
            Label(rateText(stats.download) + "/s", systemImage: "arrow.down")
            Label(rateText(stats.upload) + "/s", systemImage: "arrow.up").padding(.leading, 8)
        }
        .font(.callout.monospacedDigit())
        .padding(12)
        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private struct StatTile: View {
    let icon: String
    let title: String
    let value: String
    let detail: String
    let progress: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: icon)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 20, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText())
            Text(detail)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            ProgressView(value: min(max(progress, 0), 1))
                .tint(levelColor(progress))
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .animation(.easeOut(duration: 0.3), value: value)
    }
}

// MARK: - Clean

private struct CleanerView: View {
    @Bindable var model: CleanerModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if model.folders.isEmpty {
                Text("Add your projects folder to find build files (build, node_modules, Pods, .apk, .aab…) you can safely remove. Developer caches like DerivedData and Gradle are found automatically.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ForEach(model.folders, id: \.self) { folder in
                HStack {
                    Image(systemName: "folder").foregroundStyle(.secondary)
                    Text(folder.lastPathComponent).lineLimit(1)
                    Spacer()
                    Button { model.removeFolder(folder) } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.tertiary)
                        .help("Remove folder")
                }
                .font(.callout)
            }

            HStack {
                Button("Add Folder…") { model.addFolder() }
                Spacer()
                Button(model.scanning ? "Scanning…" : "Scan") { Task { await model.scan() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.scanning)
            }
            .controlSize(.small)

            if !model.results.isEmpty {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(model.results) { artifact in
                            ArtifactRow(artifact: artifact, isOn: Binding(
                                get: { model.selected.contains(artifact.url) },
                                set: { if $0 { model.selected.insert(artifact.url) } else { model.selected.remove(artifact.url) } }
                            ))
                        }
                    }
                }
                .frame(maxHeight: 240)

                HStack {
                    Text("\(formatBytes(model.selectedSize)) selected")
                        .font(.callout.weight(.medium))
                        .monospacedDigit()
                    Spacer()
                    Button("Move to Trash", role: .destructive) { model.trashSelected() }
                        .controlSize(.small)
                        .disabled(model.selected.isEmpty)
                }
            } else if model.hasScanned && !model.scanning {
                Label("Nothing to clean", systemImage: "checkmark.seal")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            if let freed = model.lastFreed, freed > 0 {
                Text("Moved \(formatBytes(freed)) to the Trash. Empty the Trash to get the space back.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct ArtifactRow: View {
    let artifact: Artifact
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 5) {
                        Text(artifact.url.lastPathComponent).font(.callout)
                        if artifact.isCache {
                            Text("CACHE")
                                .font(.system(size: 8.5, weight: .bold))
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(.orange.opacity(0.2), in: Capsule())
                                .foregroundStyle(.orange)
                        }
                    }
                    Text(artifact.url.deletingLastPathComponent().pathComponents.suffix(3).joined(separator: "/"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                Spacer()
                Text(formatBytes(artifact.size))
                    .font(.callout)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
        .toggleStyle(.checkbox)
        .padding(.vertical, 3)
        .help(artifact.isCache ? "Shared tool cache: safe to delete, but your next build re-downloads it." : artifact.url.path)
    }
}

// MARK: - Settings

private struct SettingsView: View {
    @AppStorage(Pref.islandVisible) private var islandVisible = true
    @AppStorage(Pref.islandIdleStats) private var idleStats = true
    @AppStorage(Pref.notifications) private var notifications = false
    @AppStorage(Pref.menu(.cpu)) private var menuCPU = true
    @AppStorage(Pref.menu(.memory)) private var menuMemory = true
    @AppStorage(Pref.menu(.temperature)) private var menuTemperature = true
    @AppStorage(Pref.menu(.network)) private var menuNetwork = true
    @AppStorage(Pref.menu(.disk)) private var menuDisk = false
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var trusted = NotificationWatcher.isTrusted

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Section("Menu bar") {
                HStack(spacing: 6) {
                    Chip(metric: .cpu, isOn: $menuCPU)
                    Chip(metric: .memory, isOn: $menuMemory)
                    Chip(metric: .temperature, isOn: $menuTemperature)
                    Chip(metric: .network, isOn: $menuNetwork)
                    Chip(metric: .disk, isOn: $menuDisk)
                }
                Text("Hold ⌘ and drag items in the menu bar to reorder them.")
                    .font(.caption).foregroundStyle(.tertiary)
            }

            Section("Island") {
                Toggle("Show island at the notch", isOn: $islandVisible)
                Toggle("Live stats beside the notch", isOn: $idleStats).disabled(!islandVisible)
                Toggle("Show other apps' notifications", isOn: $notifications)
                    .disabled(!islandVisible)
                    .onChange(of: notifications) { _, on in if on && !trusted { NotificationWatcher.requestAccess() } }
                if notifications && !trusted {
                    Text("Allow Islet in System Settings › Privacy & Security › Accessibility.")
                        .font(.caption).foregroundStyle(.orange)
                }
            }

            Section("General") {
                Toggle("Open at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in
                        do { try on ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister() }
                        catch { launchAtLogin = SMAppService.mainApp.status == .enabled }
                    }
            }
        }
        .toggleStyle(.switch)
        .controlSize(.small)
        .onAppear { trusted = NotificationWatcher.isTrusted }
    }

    private struct Section<Content: View>: View {
        let title: String
        @ViewBuilder let content: Content

        init(_ title: String, @ViewBuilder content: () -> Content) {
            self.title = title
            self.content = content()
        }

        var body: some View {
            VStack(alignment: .leading, spacing: 8) {
                Text(title.uppercased()).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                content
            }
        }
    }

    private struct Chip: View {
        let metric: Metric
        @Binding var isOn: Bool

        var body: some View {
            Button { isOn.toggle() } label: {
                Image(systemName: metric.symbol)
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 52, height: 30)
                    .background(isOn ? Color.accentColor.opacity(0.2) : Color.secondary.opacity(0.1),
                                in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .foregroundStyle(isOn ? Color.accentColor : .secondary)
            }
            .buttonStyle(.plain)
            .help(metric.title)
            .accessibilityLabel(metric.title)
            .accessibilityAddTraits(isOn ? .isSelected : [])
        }
    }
}
