import Foundation
import IOKit.ps

/// CPU, memory, disk, battery, network and top processes. Samples only while the tab is visible.
@MainActor
final class StatsService: ObservableObject {
    static let shared = StatsService()

    @Published private(set) var cpu: Double = 0
    @Published private(set) var cpuHistory: [Double] = []
    @Published private(set) var memUsed: Double = 0
    @Published private(set) var memTotal: Double = Double(ProcessInfo.processInfo.physicalMemory)
    @Published private(set) var diskFree: Double = 0
    @Published private(set) var diskTotal: Double = 0
    @Published private(set) var battery: (level: Int, charging: Bool, source: String)?
    @Published private(set) var netIn: Double = 0      // bytes/s
    @Published private(set) var netOut: Double = 0
    @Published private(set) var top: [(String, Double)] = []
    @Published private(set) var uptime: TimeInterval = 0

    private var timer: Timer?
    private var users = 0
    private var lastTicks: [UInt32]?
    private var lastNet: (UInt64, UInt64, Date)?

    func start() {
        guard timer == nil else { return }
        sample()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
            MainActor.assumeIsolated { StatsService.shared.sample() }
        }
    }

    func stop() { timer?.invalidate(); timer = nil }

    private func sample() {
        cpu = cpuUsage()
        cpuHistory.append(cpu); if cpuHistory.count > 40 { cpuHistory.removeFirst() }
        memUsed = memoryUsed()
        if let v = try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey]) {
            diskFree = Double(v.volumeAvailableCapacityForImportantUsage ?? 0)
            diskTotal = Double(v.volumeTotalCapacity ?? 0)
        }
        battery = Self.batteryInfo()
        network()
        uptime = ProcessInfo.processInfo.systemUptime
        Task {
            let (_, out) = await Shell.run("/bin/ps", ["-Aceo", "pcpu,comm", "-r"])
            top = out.split(separator: "\n").dropFirst().prefix(5).compactMap { line in
                let t = line.trimmingCharacters(in: .whitespaces)
                guard let sp = t.firstIndex(of: " "), let v = Double(t[..<sp]) else { return nil }
                return (String(t[sp...]).trimmingCharacters(in: .whitespaces), v)
            }
        }
    }

    private func cpuUsage() -> Double {
        var count: mach_msg_type_number_t = 0
        var info: processor_info_array_t?
        var ncpu: natural_t = 0
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &ncpu, &info, &count) == KERN_SUCCESS,
              let info else { return 0 }
        defer { vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), vm_size_t(count) * vm_size_t(MemoryLayout<integer_t>.size)) }
        let ticks = (0..<Int(count)).map { UInt32(bitPattern: info[$0]) }
        defer { lastTicks = ticks }
        guard let last = lastTicks, last.count == ticks.count else { return 0 }
        var busy: UInt64 = 0, total: UInt64 = 0
        for c in 0..<Int(ncpu) {
            let b = c * Int(CPU_STATE_MAX)
            let d = (0..<Int(CPU_STATE_MAX)).map { UInt64(ticks[b + $0] &- last[b + $0]) }
            busy += d[Int(CPU_STATE_USER)] + d[Int(CPU_STATE_SYSTEM)] + d[Int(CPU_STATE_NICE)]
            total += d.reduce(0, +)
        }
        return total > 0 ? Double(busy) / Double(total) : 0
    }

    private func memoryUsed() -> Double {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let r = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count) }
        }
        guard r == KERN_SUCCESS else { return 0 }
        let page = Double(vm_kernel_page_size)
        return (Double(stats.active_count) + Double(stats.wire_count) + Double(stats.compressor_page_count)) * page
    }

    private static func batteryInfo() -> (Int, Bool, String)? {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for ps in list {
            guard let d = IOPSGetPowerSourceDescription(blob, ps)?.takeUnretainedValue() as? [String: Any],
                  let cap = d[kIOPSCurrentCapacityKey] as? Int else { continue }
            return (cap, d[kIOPSIsChargingKey] as? Bool ?? false, d[kIOPSPowerSourceStateKey] as? String ?? "")
        }
        return nil
    }

    private func network() {
        var ifa: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifa) == 0 else { return }
        defer { freeifaddrs(ifa) }
        var rx: UInt64 = 0, tx: UInt64 = 0
        var p = ifa
        while let c = p {
            let name = String(cString: c.pointee.ifa_name)
            if c.pointee.ifa_addr?.pointee.sa_family == UInt8(AF_LINK), !name.hasPrefix("lo"),
               let data = c.pointee.ifa_data?.assumingMemoryBound(to: if_data.self) {
                rx += UInt64(data.pointee.ifi_ibytes); tx += UInt64(data.pointee.ifi_obytes)
            }
            p = c.pointee.ifa_next
        }
        let now = Date()
        if let (lr, lt, ld) = lastNet {
            let dt = now.timeIntervalSince(ld)
            if dt > 0, rx >= lr, tx >= lt { netIn = Double(rx - lr) / dt; netOut = Double(tx - lt) / dt }
        }
        lastNet = (rx, tx, now)
    }

    static func bytes(_ b: Double) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(b), countStyle: .memory)
    }
}
