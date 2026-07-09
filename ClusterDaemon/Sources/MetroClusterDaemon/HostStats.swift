import Foundation
import Darwin

/// Compact Darwin host sampler feeding the `.stats` heartbeat that the
/// app's MONITOR CLUSTER shows per node. CPU busy is a real
/// host_cpu_load_info tick delta, memory a real vm_statistics64 read;
/// the I/O and lock rates are synthetic-but-plausible oscillations (the
/// daemon has no meaningful I/O of its own to report).
final class HostStats {
    private var lastCPUTicks: (user: UInt32, system: UInt32, idle: UInt32, nice: UInt32)? = nil

    func snapshot() -> HostSnapshot {
        let t = Date().timeIntervalSinceReferenceDate
        return HostSnapshot(
            cpuBusy: cpuBusyPercent(),
            memUsedPercent: memUsedPercent(),
            bufferedIORate: max(0, 220 + 90 * sin(t / 7.0)),
            directIORate: max(0, 40 + 18 * sin(t / 9.0 + 1.2)),
            lockRate: max(0, 310 + 120 * sin(t / 5.0 + 2.1)),
            processCount: processCount(),
            sampledAt: Date()
        )
    }

    private func cpuBusyPercent() -> Double {
        var size = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
        var info = host_cpu_load_info_data_t()
        let result = withUnsafeMutablePointer(to: &info) { ptr -> kern_return_t in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(size)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &size)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        let ticks = (user: info.cpu_ticks.0, system: info.cpu_ticks.1,
                     idle: info.cpu_ticks.2, nice: info.cpu_ticks.3)
        defer { lastCPUTicks = ticks }
        guard let last = lastCPUTicks else { return 0 }
        let user = Double(ticks.user &- last.user)
        let system = Double(ticks.system &- last.system)
        let idle = Double(ticks.idle &- last.idle)
        let nice = Double(ticks.nice &- last.nice)
        let total = user + system + idle + nice
        guard total > 0 else { return 0 }
        return (user + system + nice) / total * 100.0
    }

    private func memUsedPercent() -> Double {
        var size = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        var stats = vm_statistics64_data_t()
        let result = withUnsafeMutablePointer(to: &stats) { ptr -> kern_return_t in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(size)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &size)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        var memBytes: UInt64 = 0
        var memSize = MemoryLayout<UInt64>.size
        sysctlbyname("hw.memsize", &memBytes, &memSize, nil, 0)
        guard memBytes > 0 else { return 0 }
        let pageSize = UInt64(vm_kernel_page_size)
        let used = (UInt64(stats.active_count) + UInt64(stats.wire_count)
                    + UInt64(stats.compressor_page_count)) * pageSize
        return Double(used) / Double(memBytes) * 100.0
    }

    private func processCount() -> Int {
        let count = proc_listallpids(nil, 0)
        return count > 0 ? Int(count) : 0
    }
}
