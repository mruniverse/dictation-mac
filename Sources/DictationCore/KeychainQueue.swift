import Foundation

/// Where keychain calls run. Any of them may wait on a system dialog (unlock the keychain, allow
/// this build to use the item), so none runs on the main thread; and they run one at a time, in
/// the order they were asked, so a lookup asked after a removal sees the removal.
public protocol KeychainQueue: Sendable {
    /// Runs `work` after everything submitted before it, then delivers its result on the main actor.
    func run<T: Sendable>(_ work: @escaping @Sendable () -> T, then deliver: @escaping @Sendable @MainActor (T) -> Void)
}

extension KeychainQueue {
    /// `work`'s result, in queue order, for async callers.
    @MainActor
    func value<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            run(work) { continuation.resume(returning: $0) }
        }
    }
}

/// One serial background queue; results come back through the main queue.
public final class SerialKeychainQueue: KeychainQueue {
    private let queue = DispatchQueue(label: "io.github.mruniverse.DictationMac.keychain", qos: .userInitiated)

    public init() {}

    public func run<T: Sendable>(_ work: @escaping @Sendable () -> T, then deliver: @escaping @Sendable @MainActor (T) -> Void) {
        queue.async {
            let value = work()
            DispatchQueue.main.async { MainActor.assumeIsolated { deliver(value) } }
        }
    }
}
