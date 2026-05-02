import Foundation
#if canImport(Darwin)
import Dispatch
#endif

/// Memory-pressure abstraction. Real instances wrap
/// `DispatchSource.makeMemoryPressureSource` on Apple platforms; the test seam allows
/// callers to fire synthetic events without actually pressuring the OS.
public protocol MemoryPressureMonitor: Sendable {
    /// Called once per pressure event. The actor implements this to drop caches and trigger
    /// an opportunistic compaction. Implementations must call `handler` from the same task /
    /// queue every time so consumers don't need to re-enter their own actor.
    func setHandler(_ handler: @escaping @Sendable (MemoryPressureLevel) -> Void)
    func cancel()
}

/// Coarse memory-pressure tier reported by the system. Mirrors `DispatchSource.MemoryPressureEvent`.
public enum MemoryPressureLevel: Sendable, Equatable {
    case warning
    case critical
}

/// Synthetic monitor used by tests. Holds onto a handler; tests fire events manually.
public final class TestMemoryPressureMonitor: MemoryPressureMonitor, @unchecked Sendable {
    private let lock = NSLock()
    private var handler: ((MemoryPressureLevel) -> Void)?

    public init() {}
    public func setHandler(_ handler: @escaping @Sendable (MemoryPressureLevel) -> Void) {
        lock.lock(); self.handler = handler; lock.unlock()
    }
    public func cancel() {
        lock.lock(); handler = nil; lock.unlock()
    }
    /// Test-only — fire an event.
    public func fire(_ level: MemoryPressureLevel) {
        lock.lock(); let h = handler; lock.unlock()
        h?(level)
    }
}

#if canImport(Darwin)
/// Apple-platform monitor backed by `DispatchSource`. Subscribes to `.warning` + `.critical`
/// events; the system delivers them on a background queue.
public final class DispatchMemoryPressureMonitor: MemoryPressureMonitor, @unchecked Sendable {
    private var source: DispatchSourceMemoryPressure?
    private let queue = DispatchQueue(label: "SwiftGraphDB.MemoryPressureMonitor", qos: .background)

    public init() {}

    public func setHandler(_ handler: @escaping @Sendable (MemoryPressureLevel) -> Void) {
        cancel()
        let s = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: queue)
        s.setEventHandler {
            let mask = s.data
            if mask.contains(.critical) { handler(.critical) }
            else if mask.contains(.warning) { handler(.warning) }
        }
        s.resume()
        self.source = s
    }

    public func cancel() {
        source?.cancel()
        source = nil
    }
}
#endif
