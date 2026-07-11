import ServiceManagement
import SwiftUI

// MARK: - Shared pieces

struct StatGauge: View {
    let title: String
    let value: Double
    let detail: String

    var body: some View {
        VStack(spacing: 2) {
            Gauge(value: min(max(value, 0), 100), in: 0...100) {
                Text(title)
            } currentValueLabel: {
                Text(Format.percent(value)).font(.system(size: 11)).monospacedDigit()
            }
            .gaugeStyle(.accessoryCircularCapacity)
            .scaleEffect(0.8)
            .frame(width: 52, height: 52)
            .tint(value > 85 ? .red : value > 65 ? .orange : .accentColor)
            Text(title).font(.caption2.weight(.semibold)).lineLimit(1)
            Text(detail).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(width: 64)
    }
}

// Speed row with a colored icon: used by both the popover and the pinned panel.
func ioRow(_ icon: String, _ tint: Color, _ label: String, _ value: String) -> some View {
    HStack(spacing: 6) {
        Image(systemName: icon).foregroundStyle(tint)
        Text(label)
        Spacer(minLength: 4)
        Text(value)
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .fixedSize()
    }
}

struct ProcessIcon: View {
    let fileName: String?
    var size: CGFloat = 16

    var body: some View {
        if let fileName,
           let image = NSImage(contentsOf: IconStore.iconURL(fileName: fileName)) {
            Image(nsImage: image)
                .resizable()
                .frame(width: size, height: size)
        } else {
            Image(systemName: "app.dashed")
                .frame(width: size, height: size)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Menu bar popover

struct StatusView: View {
    @EnvironmentObject private var engine: StatsEngine
    @Environment(\.dismiss) private var dismiss
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        let snapshot = engine.snapshot
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("MacGauge")
                    .font(.headline)
                Spacer()
                Button {
                    engine.isPanelPinned.toggle()
                    if engine.isPanelPinned {
                        dismiss() // close the popover; the pinned panel takes over
                    }
                } label: {
                    Image(systemName: engine.isPanelPinned ? "pin.slash.fill" : "pin")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help(engine.isPanelPinned ? "Unpin panel" : "Pin to top-right corner")
            }

            section("Performance") {
                HStack(spacing: 14) {
                    StatGauge(title: "CPU", value: snapshot.cpuPercent, detail: Format.temp(snapshot.cpuTemp))
                    StatGauge(title: "GPU", value: snapshot.gpuPercent, detail: Format.temp(snapshot.gpuTemp))
                    StatGauge(title: "MEM", value: snapshot.memPercent, detail: Format.bytes(snapshot.memUsedBytes))
                    StatGauge(title: "DISK", value: snapshot.diskPercent, detail: Format.bytes(snapshot.diskUsedBytes))
                }
                .frame(maxWidth: .infinity)
            }

            Divider()

            section("I/O") {
                ioRow("arrow.down.circle.fill", .blue, "Down", Format.speed(snapshot.netDownBps))
                ioRow("arrow.up.circle.fill", .green, "Up", Format.speed(snapshot.netUpBps))
                ioRow("r.circle.fill", .purple, "Read", Format.speed(snapshot.diskReadBps))
                ioRow("w.circle.fill", .orange, "Write", Format.speed(snapshot.diskWriteBps))
            }

            Divider()

            section("Top CPU") {
                ForEach(snapshot.topCPUProcesses.prefix(10)) { process in
                    HStack(spacing: 6) {
                        ProcessIcon(fileName: process.iconFileName)
                        Text(process.name).lineLimit(1).truncationMode(.tail)
                        Spacer(minLength: 4)
                        Text(String(format: "%.1f%%", process.cpuPercent))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .fixedSize()
                    }
                }
            }

            Divider()

            section("Top Network") {
                ForEach(snapshot.topNetworkProcesses.prefix(10)) { process in
                    HStack(spacing: 6) {
                        ProcessIcon(fileName: process.iconFileName)
                        Text(process.name).lineLimit(1).truncationMode(.tail)
                        Spacer(minLength: 4)
                        Text("↓ \(Format.speed(process.downBps))  ↑ \(Format.speed(process.upBps))")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .fixedSize()
                    }
                }
                if snapshot.topNetworkProcesses.isEmpty {
                    Text("No network activity")
                        .foregroundStyle(.tertiary)
                }
            }

            Divider()

            HStack {
                Toggle("Launch at Login", isOn: $launchAtLogin)
                    .toggleStyle(.checkbox)
                    .font(.callout)
                    .onChange(of: launchAtLogin) { _, enabled in
                        try? enabled ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()
                    }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
                    .font(.callout)
            }
        }
        .padding(14)
        .frame(width: 340)
    }

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            content()
        }
        .font(.callout)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Pinned panel (horizontal, small-widget height)

struct CompactStatusView: View {
    @EnvironmentObject private var engine: StatsEngine

    private let topCount = 5
    private let columnWidth: CGFloat = 160
    // Content region height = the natural height of a StatGauge block
    // (52 gauge + 2 + 13 title + 2 + 13 detail), so all four sections share
    // the same top and bottom content edges.
    private let contentHeight: CGFloat = 82
    private let titleHeight: CGFloat = 19

    var body: some View {
        let snapshot = engine.snapshot
        HStack(alignment: .top, spacing: 12) {
            section("Performance", width: 274) {
                HStack(spacing: 6) {
                    StatGauge(title: "CPU", value: snapshot.cpuPercent, detail: Format.temp(snapshot.cpuTemp))
                    StatGauge(title: "GPU", value: snapshot.gpuPercent, detail: Format.temp(snapshot.gpuTemp))
                    StatGauge(title: "MEM", value: snapshot.memPercent, detail: Format.bytes(snapshot.memUsedBytes))
                    StatGauge(title: "DISK", value: snapshot.diskPercent, detail: Format.bytes(snapshot.diskUsedBytes))
                }
                .frame(maxWidth: .infinity)
            }

            divider

            section("I/O", width: columnWidth) {
                ioRow("arrow.down.circle.fill", .blue, "Down", Format.speed(snapshot.netDownBps))
                Spacer(minLength: 0)
                ioRow("arrow.up.circle.fill", .green, "Up", Format.speed(snapshot.netUpBps))
                Spacer(minLength: 0)
                ioRow("r.circle.fill", .purple, "Read", Format.speed(snapshot.diskReadBps))
                Spacer(minLength: 0)
                ioRow("w.circle.fill", .orange, "Write", Format.speed(snapshot.diskWriteBps))
            }

            divider

            section("Top CPU", width: columnWidth) {
                let items = Array(snapshot.topCPUProcesses.prefix(topCount))
                ForEach(items) { process in
                    HStack(spacing: 4) {
                        ProcessIcon(fileName: process.iconFileName, size: 13)
                        Text(process.name).lineLimit(1).truncationMode(.tail)
                        Spacer(minLength: 4)
                        Text(String(format: "%.0f%%", process.cpuPercent))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .fixedSize()
                    }
                    if process.id != items.last?.id {
                        Spacer(minLength: 0)
                    }
                }
            }

            divider

            section("Top Network", width: columnWidth) {
                let items = Array(snapshot.topNetworkProcesses.prefix(topCount))
                ForEach(items) { process in
                    HStack(spacing: 4) {
                        ProcessIcon(fileName: process.iconFileName, size: 13)
                        Text(process.name).lineLimit(1).truncationMode(.tail)
                        Spacer(minLength: 4)
                        Text(Format.speed(process.downBps + process.upBps))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .fixedSize()
                    }
                    if process.id != items.last?.id {
                        Spacer(minLength: 0)
                    }
                }
                if items.isEmpty {
                    Text("idle").foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 14)
        .background {
            RoundedRectangle(cornerRadius: 14)
                .fill(Color(nsColor: .windowBackgroundColor))
        }
        .overlay(alignment: .topTrailing) {
            Button {
                engine.isPanelPinned = false
            } label: {
                Image(systemName: "pin.slash.fill")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .padding(8)
            .help("Unpin panel")
        }
    }

    private var divider: some View {
        Divider().frame(height: contentHeight + titleHeight)
    }

    private func section(_ title: String, width: CGFloat, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(height: titleHeight, alignment: .topLeading)
            VStack(alignment: .leading, spacing: 0) {
                content()
            }
            .frame(height: contentHeight, alignment: .topLeading)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .font(.caption)
        .frame(width: width, alignment: .topLeading)
    }

    private func ioRow(_ icon: String, _ tint: Color, _ label: String, _ value: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).foregroundStyle(tint)
            Text(label)
            Spacer(minLength: 4)
            Text(value)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .fixedSize()
        }
    }
}
