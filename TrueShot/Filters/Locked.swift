import os

/// A value behind an unfair lock — `Synchronization.Mutex`, which needs iOS 18, for iOS 17.
struct Locked<Value>: @unchecked Sendable {
    private let lock: OSAllocatedUnfairLock<Value>

    init(_ value: Value) {
        lock = OSAllocatedUnfairLock(uncheckedState: value)
    }

    func withLock<R>(_ body: (inout Value) throws -> R) rethrows -> R {
        try lock.withLockUnchecked(body)
    }
}
