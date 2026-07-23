import Foundation

@MainActor
final class StatsEngine: ObservableObject {
    @Published private(set) var snapshot: Snapshot = .placeholder
    @Published var isPanelPinned = false {
        didSet {
            guard oldValue != isPanelPinned else { return }
            if isPanelPinned {
                PinnedPanelController.shared.show(engine: self)
            } else {
                PinnedPanelController.shared.hide()
            }
        }
    }

    private let sampleInterval: TimeInterval = 2

    private let queue = DispatchQueue(label: "com.even.MacGauge.sampling", qos: .utility)
    private var timer: Timer?

    private let cpu = CPUSampler()
    private let memory = MemorySampler()
    private let gpu = GPUSampler()
    private let disk = DiskSampler()
    private let network = NetworkSampler()
    private let temperature = TemperatureSampler()
    private let processes: ProcessSampler
    private let diskProcesses: DiskUsageSampler
    private let networkProcesses: NetworkUsageSampler

    init() {
        let resolver = AppInfoResolver()
        processes = ProcessSampler(resolver: resolver)
        diskProcesses = DiskUsageSampler(resolver: resolver)
        networkProcesses = NetworkUsageSampler(resolver: resolver)
    }

    func start() {
        guard timer == nil else { return }
        IconStore.ensureDirectories()
        tick() // prime counters so the second tick has deltas
        let timer = Timer(timeInterval: sampleInterval, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func tick() {
        queue.async { [self] in
            let snapshot = buildSnapshot()
            DispatchQueue.main.async {
                self.snapshot = snapshot
            }
        }
    }

    // Runs on `queue`; samplers are only touched here after start().
    private nonisolated func buildSnapshot() -> Snapshot {
        let cpuPercent = cpu.sample()
        let memUsed = memory.sample()
        let memTotal = memory.totalBytes
        let gpuPercent = gpu.sample()
        let (diskUsed, diskTotal) = disk.sampleUsage()
        let (readBps, writeBps) = disk.sampleIO()
        let (upBps, downBps) = network.sample()
        let temps = temperature.sample()
        let topCPU = processes.sample(topCount: 10)
        let topDisk = diskProcesses.sample(topCount: 10)
        let topNet = networkProcesses.sample(topCount: 10)

        return Snapshot(
            timestamp: Date(),
            cpuPercent: cpuPercent,
            gpuPercent: gpuPercent,
            memPercent: memTotal > 0 ? Double(memUsed) / Double(memTotal) * 100 : 0,
            memUsedBytes: memUsed,
            memTotalBytes: memTotal,
            diskPercent: diskTotal > 0 ? Double(diskUsed) / Double(diskTotal) * 100 : 0,
            diskUsedBytes: diskUsed,
            diskTotalBytes: diskTotal,
            diskReadBps: readBps,
            diskWriteBps: writeBps,
            netUpBps: upBps,
            netDownBps: downBps,
            cpuTemp: temps.cpu,
            gpuTemp: temps.gpu,
            topCPUProcesses: topCPU,
            topDiskProcesses: topDisk,
            topNetworkProcesses: topNet
        )
    }
}
