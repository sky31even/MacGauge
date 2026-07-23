import Foundation

struct ProcessSample: Identifiable, Hashable {
    var pid: Int32
    var name: String
    var cpuPercent: Double // % of one core, Activity Monitor style
    var iconFileName: String?

    var id: Int32 { pid }
}

struct NetworkProcessSample: Identifiable, Hashable {
    var pid: Int32
    var name: String
    var downBps: Double
    var upBps: Double
    var iconFileName: String?

    var id: Int32 { pid }
}

struct DiskProcessSample: Identifiable, Hashable {
    var pid: Int32
    var name: String
    var readBps: Double
    var writeBps: Double
    var iconFileName: String?

    var id: Int32 { pid }
}

struct Snapshot {
    var timestamp: Date

    var cpuPercent: Double // 0-100
    var gpuPercent: Double // 0-100
    var memPercent: Double // 0-100
    var memUsedBytes: UInt64
    var memTotalBytes: UInt64

    var diskPercent: Double // 0-100, boot volume space used
    var diskUsedBytes: UInt64
    var diskTotalBytes: UInt64
    var diskReadBps: Double
    var diskWriteBps: Double

    var netUpBps: Double
    var netDownBps: Double

    var cpuTemp: Double? // °C, nil if sensors unavailable
    var gpuTemp: Double?

    var topCPUProcesses: [ProcessSample]
    var topDiskProcesses: [DiskProcessSample]
    var topNetworkProcesses: [NetworkProcessSample]

    static let placeholder = Snapshot(
        timestamp: Date(),
        cpuPercent: 0, gpuPercent: 0, memPercent: 0,
        memUsedBytes: 0, memTotalBytes: 0,
        diskPercent: 0, diskUsedBytes: 0, diskTotalBytes: 0,
        diskReadBps: 0, diskWriteBps: 0,
        netUpBps: 0, netDownBps: 0,
        cpuTemp: nil, gpuTemp: nil,
        topCPUProcesses: [], topDiskProcesses: [], topNetworkProcesses: []
    )
}

enum IconStore {
    static var baseURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/MacGauge", isDirectory: true)
    }

    static var iconsURL: URL { baseURL.appendingPathComponent("icons", isDirectory: true) }

    static func iconURL(fileName: String) -> URL {
        iconsURL.appendingPathComponent(fileName)
    }

    static func ensureDirectories() {
        try? FileManager.default.createDirectory(at: iconsURL, withIntermediateDirectories: true)
    }
}

enum Format {
    static func bytes(_ value: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(value), countStyle: .memory)
    }

    static func speed(_ bps: Double) -> String {
        let value = max(0, bps)
        switch value {
        case ..<1_000: return String(format: "%.0f B/s", value)
        case ..<1_000_000: return String(format: "%.0f KB/s", value / 1_000)
        case ..<1_000_000_000: return String(format: "%.1f MB/s", value / 1_000_000)
        default: return String(format: "%.2f GB/s", value / 1_000_000_000)
        }
    }

    static func percent(_ value: Double) -> String {
        String(format: "%.0f%%", value)
    }

    static func temp(_ value: Double?) -> String {
        guard let value else { return "--" }
        return String(format: "%.0f°", value)
    }
}
