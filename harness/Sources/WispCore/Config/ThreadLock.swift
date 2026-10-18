import Darwin
import Foundation
import Synchronization

/// The lock that keeps a saved thread to one process at a time
/// ([ADR 0066](../../../../docs/decisions/0066-one-thread-store.md), D6): an advisory `flock` on
/// `threads/<id>/lock`, taken when the thread is opened or resumed and released when it is closed, evicted, or saved
/// at a client's end. The kernel releases it when the process ends, a crash included, so a lock never outlives its
/// holder. The file records the holder's pid and owner for the refusal another process gives.
///
/// `flock` locks belong to an open file description, so two opens of the file in one process exclude each other as
/// two processes do. A `final class` with a `Mutex`: releasing is a short synchronous critical section.
public final class ThreadLock: Sendable {
    /// Who holds a lock, as its file records them.
    public struct Holder: Codable, Sendable, Equatable {
        /// The holding process.
        public var pid: Int32
        /// The thread's owner as the holder named it: `chat`, or an MCP client's name; nil when unknown.
        public var owner: String?

        /// Creates a holder.
        ///
        /// - Parameters:
        ///   - pid: The process.
        ///   - owner: The owner it names.
        public init(pid: Int32, owner: String?) {
            self.pid = pid
            self.owner = owner
        }
    }

    /// What taking a lock came to.
    enum Taken {
        /// The lock is this process's.
        case acquired(ThreadLock)
        /// Another open file description holds it; who, when its file says.
        case held(Holder?)
        /// The lock file could not be opened or locked, for the reason given.
        case failed(String)
    }

    /// The lock file.
    public let url: URL
    /// The open descriptor holding the lock; nil once released.
    private let descriptor: Mutex<Int32?>

    /// Wraps a descriptor that holds the lock.
    ///
    /// - Parameters:
    ///   - url: The lock file.
    ///   - descriptor: The descriptor.
    private init(url: URL, descriptor: Int32) {
        self.url = url
        self.descriptor = Mutex(descriptor)
    }

    deinit { release() }

    /// Takes the lock at `url` without waiting, creating the file user-only, and records `holder` in it.
    ///
    /// - Parameters:
    ///   - url: The lock file; its directory must exist.
    ///   - holder: Who takes it.
    /// - Returns: The lock, who holds it instead, or why it could not be taken.
    static func take(at url: URL, holder: Holder) -> Taken {
        let descriptor = open(url.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { return .failed(String(cString: strerror(errno))) }
        while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            let error = errno
            if error == EINTR { continue }
            _ = close(descriptor)
            return error == EWOULDBLOCK ? .held(Self.holder(in: url)) : .failed(String(cString: strerror(error)))
        }
        if let data = try? JSONEncoder().encode(holder) {
            _ = ftruncate(descriptor, 0)
            _ = data.withUnsafeBytes { pwrite(descriptor, $0.baseAddress, data.count, 0) }
        }
        return .acquired(ThreadLock(url: url, descriptor: descriptor))
    }

    /// Whether another open file description holds the lock at `url` now; false when nobody does or there is no lock
    /// file. Probing takes the lock for an instant when it is free, so a holder in this process on another descriptor
    /// counts as one elsewhere.
    ///
    /// - Parameter url: The lock file.
    /// - Returns: Whether it is held.
    static func isHeld(_ url: URL) -> Bool {
        let descriptor = open(url.path, O_RDWR | O_CLOEXEC)
        guard descriptor >= 0 else { return false }
        defer { _ = close(descriptor) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) != 0 else {
            _ = flock(descriptor, LOCK_UN)
            return false
        }
        return true
    }

    /// The holder a lock file records, or nil when it records none that decodes.
    ///
    /// - Parameter url: The lock file.
    /// - Returns: The holder, or nil.
    static func holder(in url: URL) -> Holder? {
        (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(Holder.self, from: $0) }
    }

    /// Whether this lock is still held by this process.
    public var isHeld: Bool { descriptor.withLock { $0 != nil } }

    /// Releases the lock; a second call does nothing.
    public func release() {
        let held = descriptor.withLock { descriptor -> Int32? in
            defer { descriptor = nil }
            return descriptor
        }
        guard let held else { return }
        _ = flock(held, LOCK_UN)
        _ = close(held)
    }
}
