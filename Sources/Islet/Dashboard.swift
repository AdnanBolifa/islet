import IsletCore
import SwiftUI

struct DashboardView: View {
    enum Tab: String, CaseIterable { case overview = "Overview", clean = "Clean" }

    let stats: StatsModel
    let cleaner: CleanerModel
    let onIslandToggle: (Bool) -> Void

    @State private var tab = Tab.overview
    @AppStorage("showIsland") private var showIsland = true

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
                .frame(width: 170)
            }

            switch tab {
            case .overview: OverviewView(stats: stats)
            case .clean: CleanerView(model: cleaner)
            }

            Divider()

            HStack {
                Toggle("Notch island", isOn: $showIsland)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
            }
            .font(.callout)
        }
        .padding(16)
        .frame(width: 340)
        .onChange(of: showIsland) { _, visible in onIslandToggle(visible) }
    }
}

private struct OverviewView: View {
    let stats: StatsModel

    var body: some View {
        let memory = stats.memory
        let disk = stats.disk
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible())], spacing: 10) {
            StatTile(icon: "cpu", title: "CPU",
                     value: stats.cpu.formatted(.percent.precision(.fractionLength(0))),
                     detail: "\(ProcessInfo.processInfo.activeProcessorCount) cores",
                     progress: stats.cpu)
            StatTile(icon: "memorychip", title: "Memory",
                     value: formatBytes(memory.used, style: .memory),
                     detail: "of \(formatBytes(memory.total, style: .memory)) · \(formatBytes(memory.swapUsed, style: .memory)) swap",
                     progress: memory.fraction)
            StatTile(icon: "internaldrive", title: "Disk",
                     value: formatBytes(disk.free),
                     detail: "free of \(formatBytes(disk.total))",
                     progress: disk.usedFraction)
            StatTile(icon: "thermometer.medium", title: "Thermal",
                     value: stats.thermal.label,
                     detail: "system state",
                     progress: stats.thermal.level)
        }
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
                .tint(progress < 0.6 ? .green : progress < 0.85 ? .orange : .red)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .animation(.easeOut(duration: 0.3), value: value)
    }
}

private struct CleanerView: View {
    @Bindable var model: CleanerModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if model.folders.isEmpty {
                Text("Add your projects folder to find build files (build, node_modules, Pods, .apk, .aab…) you can safely remove.")
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
                    .disabled(model.folders.isEmpty || model.scanning)
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
                    Text(artifact.url.lastPathComponent).font(.callout)
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
    }
}
