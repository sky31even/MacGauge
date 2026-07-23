import AppKit
import Darwin
import Foundation
import IOKit

// MARK: - CPU (total, via host_processor_info tick deltas)

final class CPUSampler {
    private var prevBusy: UInt64 = 0
    private var prevTotal: UInt64 = 0

    func sample() -> Double {
        var cpuCount: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &cpuCount, &info, &infoCount) == KERN_SUCCESS,
              let info else { return 0 }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: info)),
                          vm_size_t(infoCount) * vm_size_t(MemoryLayout<integer_t>.stride))
        }

        var busy: UInt64 = 0
        var total: UInt64 = 0
        for cpu in 0..<Int(cpuCount) {
            let base = cpu * Int(CPU_STATE_MAX)
            let user = UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_USER)]))
            let system = UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_SYSTEM)]))
            let nice = UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_NICE)]))
            let idle = UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_IDLE)]))
            busy += user + system + nice
            total += user + system + nice + idle
        }

        defer { prevBusy = busy; prevTotal = total }
        let dBusy = busy &- prevBusy
        let dTotal = total &- prevTotal
        guard prevTotal > 0, dTotal > 0 else { return 0 }
        return min(100, Double(dBusy) / Double(dTotal) * 100)
    }
}

// MARK: - Memory (Activity Monitor style: app memory + wired + compressed)

final class MemorySampler {
    let totalBytes = ProcessInfo.processInfo.physicalMemory

    func sample() -> UInt64 {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        let pageSize = UInt64(vm_kernel_page_size)
        let appPages = stats.internal_page_count >= stats.purgeable_count
            ? stats.internal_page_count - stats.purgeable_count : 0
        return (UInt64(appPages) + UInt64(stats.wire_count) + UInt64(stats.compressor_page_count)) * pageSize
    }
}

// MARK: - GPU (IOAccelerator PerformanceStatistics)

final class GPUSampler {
    func sample() -> Double {
        var iterator = io_iterator_t()
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) == KERN_SUCCESS else {
            return 0
        }
        defer { IOObjectRelease(iterator) }

        var best = 0.0
        var entry = IOIteratorNext(iterator)
        while entry != 0 {
            if let stats = IORegistryEntryCreateCFProperty(entry, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? [String: Any] {
                let value = (stats["Device Utilization %"] as? Double)
                    ?? (stats["GPU Activity(%)"] as? Double) ?? 0
                best = max(best, value)
            }
            IOObjectRelease(entry)
            entry = IOIteratorNext(iterator)
        }
        return min(100, best)
    }
}

// MARK: - Disk (boot volume usage + IOBlockStorageDriver byte counters)

final class DiskSampler {
    private var prevRead: UInt64 = 0
    private var prevWrite: UInt64 = 0
    private var prevTime: Date?

    func sampleUsage() -> (used: UInt64, total: UInt64) {
        guard let values = try? URL(fileURLWithPath: "/").resourceValues(
            forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]),
            let total = values.volumeTotalCapacity,
            let available = values.volumeAvailableCapacityForImportantUsage else { return (0, 0) }
        return (UInt64(max(0, Int64(total) - available)), UInt64(total))
    }

    func sampleIO() -> (readBps: Double, writeBps: Double) {
        var read: UInt64 = 0
        var write: UInt64 = 0
        var iterator = io_iterator_t()
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOBlockStorageDriver"), &iterator) == KERN_SUCCESS else {
            return (0, 0)
        }
        var entry = IOIteratorNext(iterator)
        while entry != 0 {
            if let stats = IORegistryEntryCreateCFProperty(entry, "Statistics" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? [String: Any] {
                read += (stats["Bytes (Read)"] as? UInt64) ?? 0
                write += (stats["Bytes (Write)"] as? UInt64) ?? 0
            }
            IOObjectRelease(entry)
            entry = IOIteratorNext(iterator)
        }
        IOObjectRelease(iterator)

        let now = Date()
        defer { prevRead = read; prevWrite = write; prevTime = now }
        guard let prevTime else { return (0, 0) }
        let dt = now.timeIntervalSince(prevTime)
        guard dt > 0, read >= prevRead, write >= prevWrite else { return (0, 0) }
        return (Double(read - prevRead) / dt, Double(write - prevWrite) / dt)
    }
}

// MARK: - Network (getifaddrs byte counters, per-interface wrap handling)

final class NetworkSampler {
    private var prevCounters: [String: (rx: UInt64, tx: UInt64)] = [:]
    private var prevTime: Date?

    func sample() -> (upBps: Double, downBps: Double) {
        var counters: [String: (rx: UInt64, tx: UInt64)] = [:]
        var ifaddrPtr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddrPtr) == 0 else { return (0, 0) }
        defer { freeifaddrs(ifaddrPtr) }

        var ptr = ifaddrPtr
        while let current = ptr {
            defer { ptr = current.pointee.ifa_next }
            let ifa = current.pointee
            guard let addr = ifa.ifa_addr, addr.pointee.sa_family == UInt8(AF_LINK),
                  let dataPtr = ifa.ifa_data else { continue }
            let name = String(cString: ifa.ifa_name)
            // Physical-ish interfaces only; skip loopback, AWDL, tunnels.
            guard name.hasPrefix("en") || name.hasPrefix("bridge") || name.hasPrefix("pdp") else { continue }
            let data = dataPtr.assumingMemoryBound(to: if_data.self).pointee
            let existing = counters[name] ?? (0, 0)
            counters[name] = (existing.rx + UInt64(data.ifi_ibytes), existing.tx + UInt64(data.ifi_obytes))
        }

        let now = Date()
        defer { prevCounters = counters; prevTime = now }
        guard let prevTime else { return (0, 0) }
        let dt = now.timeIntervalSince(prevTime)
        guard dt > 0 else { return (0, 0) }

        var rxDelta: UInt64 = 0
        var txDelta: UInt64 = 0
        for (name, current) in counters {
            guard let prev = prevCounters[name] else { continue }
            // ifi_ibytes/ifi_obytes are 32-bit and wrap; correct single wraps.
            rxDelta += current.rx >= prev.rx ? current.rx - prev.rx : current.rx &+ (1 << 32) &- prev.rx
            txDelta += current.tx >= prev.tx ? current.tx - prev.tx : current.tx &+ (1 << 32) &- prev.tx
        }
        return (Double(txDelta) / dt, Double(rxDelta) / dt)
    }
}

// MARK: - Temperature (Apple Silicon HID sensors, see SensorReader.c)

final class TemperatureSampler {
    func sample() -> (cpu: Double?, gpu: Double?) {
        let temps = mg_read_temps()
        return (temps.cpu > 0 ? temps.cpu : nil, temps.gpu > 0 ? temps.gpu : nil)
    }
}

// MARK: - Process name/icon resolution (shared by CPU and network samplers)

final class AppInfoResolver {
    private var exportedIcons: Set<String> = []

    func describe(pid: pid_t) -> (name: String, iconFile: String?)? {
        var pathBuffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let pathLength = proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count))
        let path = pathLength > 0 ? String(cString: pathBuffer) : nil

        let runningApp = NSRunningApplication(processIdentifier: pid)
        let name = runningApp?.localizedName
            ?? path.map { URL(fileURLWithPath: $0).lastPathComponent }
        guard let name, !name.isEmpty else { return nil }

        var icon = runningApp?.icon
        if icon == nil, let path {
            // Show the owning .app bundle's icon for helper processes if there is one.
            if let appRange = path.range(of: ".app/") {
                icon = NSWorkspace.shared.icon(forFile: String(path[..<appRange.lowerBound]) + ".app")
            } else {
                icon = NSWorkspace.shared.icon(forFile: path)
            }
        }
        return (name, icon.flatMap { export(icon: $0, name: name) })
    }

    private func export(icon: NSImage, name: String) -> String? {
        let safeName = name.unicodeScalars
            .map { CharacterSet.alphanumerics.contains($0) ? Character($0) : "_" }
            .reduce(into: "") { $0.append($1) }
        let fileName = "\(safeName).png"
        if exportedIcons.contains(fileName) { return fileName }

        let size = NSSize(width: 40, height: 40)
        let resized = NSImage(size: size)
        resized.lockFocus()
        icon.draw(in: NSRect(origin: .zero, size: size), from: .zero, operation: .copy, fraction: 1)
        resized.unlockFocus()
        guard let tiff = resized.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return nil }
        do {
            try png.write(to: IconStore.iconURL(fileName: fileName), options: .atomic)
            exportedIcons.insert(fileName)
            return fileName
        } catch {
            return nil
        }
    }
}

// MARK: - Top processes by CPU (libproc rusage deltas)

final class ProcessSampler {
    private let resolver: AppInfoResolver
    private var prevCPUTime: [pid_t: UInt64] = [:]
    private var prevSampleTime: UInt64 = 0
    private var timebase = mach_timebase_info_data_t()

    init(resolver: AppInfoResolver) {
        self.resolver = resolver
        mach_timebase_info(&timebase)
    }

    func sample(topCount: Int) -> [ProcessSample] {
        let capacity = 8192
        var pids = [pid_t](repeating: 0, count: capacity)
        let byteCount = proc_listallpids(&pids, Int32(capacity * MemoryLayout<pid_t>.stride))
        guard byteCount > 0 else { return [] }
        let pidCount = min(Int(byteCount), capacity)

        let now = mach_absolute_time()
        var cpuTimes: [pid_t: UInt64] = [:]
        var deltas: [(pid: pid_t, cpuNs: UInt64)] = []

        for i in 0..<pidCount {
            let pid = pids[i]
            guard pid > 0 else { continue }
            var usage = rusage_info_current()
            let result = withUnsafeMutablePointer(to: &usage) {
                $0.withMemoryRebound(to: (rusage_info_t?).self, capacity: 1) {
                    proc_pid_rusage(pid, RUSAGE_INFO_CURRENT, $0)
                }
            }
            guard result == 0 else { continue }
            let machTime = usage.ri_user_time &+ usage.ri_system_time
            let ns = machTime &* UInt64(timebase.numer) / UInt64(timebase.denom)
            cpuTimes[pid] = ns
            if let prev = prevCPUTime[pid], ns >= prev {
                deltas.append((pid, ns - prev))
            }
        }

        let intervalNs = (now &- prevSampleTime) &* UInt64(timebase.numer) / UInt64(timebase.denom)
        let hadPrev = prevSampleTime > 0
        prevCPUTime = cpuTimes
        prevSampleTime = now
        guard hadPrev, intervalNs > 0 else { return [] }

        return deltas
            .sorted { $0.cpuNs > $1.cpuNs }
            .prefix(topCount)
            .compactMap { item in
                let percent = Double(item.cpuNs) / Double(intervalNs) * 100
                guard let (name, iconFile) = resolver.describe(pid: item.pid) else { return nil }
                return ProcessSample(pid: item.pid, name: name, cpuPercent: percent, iconFileName: iconFile)
            }
    }
}

// MARK: - Top processes by disk I/O (libproc rusage deltas)

final class DiskUsageSampler {
    private let resolver: AppInfoResolver
    private var prevIO: [pid_t: (read: UInt64, write: UInt64)] = [:]
    private var prevTime: Date?

    init(resolver: AppInfoResolver) {
        self.resolver = resolver
    }

    func sample(topCount: Int) -> [DiskProcessSample] {
        let capacity = 8192
        var pids = [pid_t](repeating: 0, count: capacity)
        let byteCount = proc_listallpids(&pids, Int32(capacity * MemoryLayout<pid_t>.stride))
        guard byteCount > 0 else { return [] }
        let pidCount = min(Int(byteCount), capacity)

        var counters: [pid_t: (read: UInt64, write: UInt64)] = [:]
        for i in 0..<pidCount {
            let pid = pids[i]
            guard pid > 0 else { continue }
            var usage = rusage_info_current()
            let result = withUnsafeMutablePointer(to: &usage) {
                $0.withMemoryRebound(to: (rusage_info_t?).self, capacity: 1) {
                    proc_pid_rusage(pid, RUSAGE_INFO_CURRENT, $0)
                }
            }
            guard result == 0 else { continue }
            counters[pid] = (usage.ri_diskio_bytesread, usage.ri_diskio_byteswritten)
        }

        let now = Date()
        defer { prevIO = counters; prevTime = now }
        guard let prevTime else { return [] }
        let dt = now.timeIntervalSince(prevTime)
        guard dt > 0 else { return [] }

        return counters
            .compactMap { pid, current -> (pid: pid_t, read: Double, write: Double)? in
                // Counters can reset when a pid is reused; skip regressions.
                guard let prev = prevIO[pid],
                      current.read >= prev.read, current.write >= prev.write else { return nil }
                let read = Double(current.read - prev.read) / dt
                let write = Double(current.write - prev.write) / dt
                guard read + write > 0 else { return nil }
                return (pid, read, write)
            }
            .sorted { $0.read + $0.write > $1.read + $1.write }
            .prefix(topCount)
            .compactMap { item in
                guard let (name, iconFile) = resolver.describe(pid: item.pid) else { return nil }
                return DiskProcessSample(pid: item.pid, name: name,
                                         readBps: item.read, writeBps: item.write,
                                         iconFileName: iconFile)
            }
    }
}

// MARK: - Top processes by network usage (nettop counter deltas)

final class NetworkUsageSampler {
    private let resolver: AppInfoResolver
    private var prevCounters: [Int32: (rx: UInt64, tx: UInt64, name: String)] = [:]
    private var prevTime: Date?

    init(resolver: AppInfoResolver) {
        self.resolver = resolver
    }

    func sample(topCount: Int) -> [NetworkProcessSample] {
        let counters = readCounters()
        let now = Date()
        defer { prevCounters = counters; prevTime = now }
        guard let prevTime else { return [] }
        let dt = now.timeIntervalSince(prevTime)
        guard dt > 0 else { return [] }

        return counters
            .compactMap { pid, current -> (pid: Int32, name: String, down: Double, up: Double)? in
                guard let prev = prevCounters[pid],
                      current.rx >= prev.rx, current.tx >= prev.tx else { return nil }
                let down = Double(current.rx - prev.rx) / dt
                let up = Double(current.tx - prev.tx) / dt
                guard down + up > 0 else { return nil }
                return (pid, current.name, down, up)
            }
            .sorted { $0.down + $0.up > $1.down + $1.up }
            .prefix(topCount)
            .map { item in
                // nettop truncates names; prefer the resolver's, keep its icon.
                let described = resolver.describe(pid: item.pid)
                return NetworkProcessSample(
                    pid: item.pid,
                    name: described?.name ?? item.name,
                    downBps: item.down,
                    upBps: item.up,
                    iconFileName: described?.iconFile
                )
            }
    }

    // `nettop -P -x -L 1` prints one CSV line per process: "name.pid,bytes_in,bytes_out,"
    private func readCounters() -> [Int32: (rx: UInt64, tx: UInt64, name: String)] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/nettop")
        process.arguments = ["-P", "-x", "-L", "1", "-J", "bytes_in,bytes_out"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return [:] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard let output = String(data: data, encoding: .utf8) else { return [:] }

        var counters: [Int32: (rx: UInt64, tx: UInt64, name: String)] = [:]
        for line in output.split(separator: "\n") {
            let fields = line.split(separator: ",", omittingEmptySubsequences: false)
            guard fields.count >= 3,
                  let dotIndex = fields[0].lastIndex(of: "."),
                  let pid = Int32(fields[0][fields[0].index(after: dotIndex)...]),
                  let rx = UInt64(fields[1]), let tx = UInt64(fields[2]) else { continue }
            counters[pid] = (rx, tx, String(fields[0][..<dotIndex]))
        }
        return counters
    }
}
