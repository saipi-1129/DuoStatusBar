import Foundation
import Darwin
import Dispatch

enum MemoryPressureLevel: Equatable {
    case normal
    case warning
    case critical

    static func from(_ event: DispatchSource.MemoryPressureEvent) -> Self {
        if event.contains(.critical) { return .critical }
        if event.contains(.warning) { return .warning }
        return .normal
    }
}

enum StatusMetric: String, CaseIterable, Identifiable {
    case cpu, memory, volume
    var id: String { rawValue }
    var title: String {
        switch self { case .cpu: return "CPU"; case .memory: return "メモリ"; case .volume: return "音量" }
    }
    var shortTitle: String {
        switch self { case .cpu: return "CPU"; case .memory: return "MEM"; case .volume: return "VOL" }
    }
    func value(_ snapshot: StatusSnapshot) -> Int? {
        switch self {
        case .cpu: return snapshot.cpuPercent
        case .memory: return snapshot.memoryPercent
        case .volume: return snapshot.volumePercent
        }
    }
    static var selected: StatusMetric {
        StatusMetric(rawValue: UserDefaults.standard.string(forKey: "statusMetric") ?? "cpu") ?? .cpu
    }
    func displayValue(_ snapshot: StatusSnapshot) -> String {
        if self == .memory {
            guard let bytes = snapshot.memoryBytes else { return "—" }
            return String(format: "%.1fG", Double(bytes) / 1_073_741_824)
        }
        return value(snapshot).map { "\($0)%" } ?? "—"
    }
}

final class SystemMetrics {
    static let updateInterval: TimeInterval = 3
    private var pressureSource: (any DispatchSourceMemoryPressure)?
    private(set) var memoryPressure: MemoryPressureLevel = .normal
    private var lastSample: TimeInterval?
    private var cached: (cpu: Int?, memory: Int?) = (nil, nil)
    private var previousCPU: [UInt32]?
    private var lastMetric: StatusMetric?
    private(set) var cpuReadCount = 0
    private(set) var memoryReadCount = 0
    private(set) var memoryBytes: UInt64?

    init() {
        let source = DispatchSource.makeMemoryPressureSource(eventMask: .all, queue: .main)
        pressureSource = source
        source.setEventHandler { [weak self] in
            self?.memoryPressure = MemoryPressureLevel.from(source.data)
        }
        source.activate()
    }

    deinit {
        pressureSource?.cancel()
    }
    static func cpuUsage(previous: [UInt32], current: [UInt32]) -> Int? {
        guard previous.count == 4, current.count == 4 else { return nil }
        let delta = zip(current, previous).map { UInt64($0 &- $1) }
        let total = delta.reduce(0, +)
        guard total > 0 else { return nil }
        return Int((100 * Double(total - delta[Int(CPU_STATE_IDLE)]) / Double(total)).rounded())
    }
    static func usedMemoryPages(
        physicalPages: UInt64,
        freePages: UInt64,
        speculativePages: UInt64,
        purgeablePages: UInt64,
        externalPages: UInt64
    ) -> UInt64 {
        let reclaimableFreePages = freePages >= speculativePages
            ? freePages - speculativePages
            : 0
        let reclaimablePages = min(
            physicalPages,
            reclaimableFreePages + min(physicalPages, purgeablePages + externalPages)
        )
        return physicalPages - reclaimablePages
    }
    func sample(for metric: StatusMetric) -> (cpu: Int?, memory: Int?) {
        if lastMetric != metric {
            lastMetric = metric
            lastSample = nil
            cached = (nil, nil)
            previousCPU = nil
            memoryBytes = nil
        }
        guard metric != .volume else { return cached }
        let now = ProcessInfo.processInfo.systemUptime
        if let lastSample, now - lastSample < Self.updateInterval { return cached }
        lastSample = now
        switch metric {
        case .cpu:
            cached = (readCPU(), nil)
        case .memory:
            cached = (nil, readMemory())
        case .volume:
            cached = (nil, nil)
        }
        return cached
    }

    private func readCPU() -> Int? {
        cpuReadCount += 1
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }
        var cpu = host_cpu_load_info_data_t()
        var cpuCount = mach_msg_type_number_t(MemoryLayout.size(ofValue: cpu) / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &cpu) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(cpuCount)) {
                host_statistics(host, HOST_CPU_LOAD_INFO, $0, &cpuCount)
            }
        }
        guard result == KERN_SUCCESS else {
            previousCPU = nil
            return nil
        }
        let ticks = [cpu.cpu_ticks.0, cpu.cpu_ticks.1, cpu.cpu_ticks.2, cpu.cpu_ticks.3]
        defer { previousCPU = ticks }
        guard let previousCPU else { return nil }
        return Self.cpuUsage(previous: previousCPU, current: ticks)
    }

    private func readMemory() -> Int? {
        memoryReadCount += 1
        memoryBytes = nil
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }
        var vm = vm_statistics64_data_t()
        var vmCount = mach_msg_type_number_t(MemoryLayout.size(ofValue: vm) / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &vm) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(vmCount)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &vmCount)
            }
        }
        var pageSize: vm_size_t = 0
        guard result == KERN_SUCCESS, host_page_size(host, &pageSize) == KERN_SUCCESS else { return nil }
        // Match Activity Monitor's "Memory Used": physical memory minus
        // immediately reclaimable free/speculative pages and cached files.
        let physicalPages = UInt64(ProcessInfo.processInfo.physicalMemory) / UInt64(pageSize)
        let pages = Self.usedMemoryPages(
            physicalPages: physicalPages,
            freePages: UInt64(vm.free_count),
            speculativePages: UInt64(vm.speculative_count),
            purgeablePages: UInt64(vm.purgeable_count),
            externalPages: UInt64(vm.external_page_count)
        )
        let fraction = Double(pages) / Double(max(1, physicalPages))
        memoryBytes = pages * UInt64(pageSize)
        return Int((min(1, max(0, fraction)) * 100).rounded())
    }
}
