import Darwin

/// The Mac's memory as the kernel reports it now: installed, and available to a new allocation without
/// swapping (free, inactive, purgeable, and speculative pages). Read to size a local model's context
/// window ([ADR 0043](../../../../docs/decisions/0043-context-window-from-memory.md)).
public struct MemoryState: Equatable, Sendable {
    /// Installed memory, in bytes.
    public var installed: Int
    /// Memory available now, in bytes.
    public var available: Int

    /// Creates a reading.
    public init(installed: Int, available: Int) {
        self.installed = installed
        self.available = available
    }

    /// The memory now; `available` is 0 when the kernel does not answer.
    public static func current() -> MemoryState {
        var statistics = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &statistics) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        let installed = Int(clamping: ProcessTable.installedBytes)
        guard result == KERN_SUCCESS else { return MemoryState(installed: installed, available: 0) }
        let pages =
            UInt64(statistics.free_count) + UInt64(statistics.inactive_count) + UInt64(statistics.purgeable_count)
            + UInt64(statistics.speculative_count)
        return MemoryState(installed: installed, available: Int(clamping: pages * UInt64(getpagesize())))
    }
}
