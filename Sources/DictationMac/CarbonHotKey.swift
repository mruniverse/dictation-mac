import Carbon
import DictationCore
import Foundation

struct CarbonHotKeyEvent: Sendable {
    var eventClass: UInt32
    var kind: UInt32
    var signature: UInt32
    var id: UInt32
}

@MainActor
protocol CarbonHotKeyBackend: AnyObject, Sendable {
    func install(_ handler: @escaping @MainActor (CarbonHotKeyEvent) -> Bool) throws
    func register(_ chord: CarbonHotKey.Chord, signature: UInt32, id: UInt32) throws
    func unregister()
    func removeHandler()
}

/// Registers only one exclusive chord; construction does not register or observe keys.
@MainActor
final class CarbonHotKey {
    struct Chord: Equatable, Sendable {
        var keyCode: UInt32
        var modifiers: UInt32
        static let controlShiftD = Chord(keyCode: UInt32(kVK_ANSI_D), modifiers: UInt32(controlKey | shiftKey))
        var isValid: Bool {
            let supported = UInt32(cmdKey | optionKey | controlKey | shiftKey)
            return keyCode < 128 && !(54...63).contains(keyCode)
                && keyCode != UInt32(kVK_Return) && keyCode != UInt32(kVK_ANSI_KeypadEnter)
                && modifiers != 0 && modifiers & ~supported == 0
        }
    }

    private(set) var registration: UUID?
    private static var nextID: UInt32 = 0
    enum Failure: Error { case invalidChord, identifiersExhausted, cleanupPending, missingResource, native(OSStatus) }
    private let backend: CarbonHotKeyBackend

    init(backend: CarbonHotKeyBackend = NativeCarbonHotKeyBackend()) { self.backend = backend }

    deinit {
        let backend = backend
        let cleanup: @MainActor @Sendable () -> Void = {
            backend.unregister()
            backend.removeHandler()
        }
        if Thread.isMainThread { MainActor.assumeIsolated(cleanup) }
        else { DispatchQueue.main.async { cleanup() } }
    }

    /// Future binding must deactivate its core before replacement/disable and on any thrown error.
    @discardableResult
    func activate(chord: Chord, receive: @escaping @MainActor (PushToTalkEvent, UUID) -> Void) throws -> UUID {
        deactivate()
        guard chord.isValid else { throw Failure.invalidChord }
        let generation = UUID()
        guard Self.nextID < .max else { throw Failure.identifiersExhausted }
        Self.nextID += 1
        let id = Self.nextID
        let signature: UInt32 = 0x44505454
        do {
            try backend.install { [weak self] event in
                guard self?.registration == generation,
                      event.eventClass == UInt32(kEventClassKeyboard),
                      event.signature == signature, event.id == id else { return false }
                let kind: PushToTalkEvent
                switch event.kind {
                case UInt32(kEventHotKeyPressed): kind = .pressed
                case UInt32(kEventHotKeyReleased): kind = .released
                default: return false
                }
                receive(kind, generation)
                return true
            }
            try backend.register(chord, signature: signature, id: id)
        } catch {
            deactivate()
            throw error
        }
        registration = generation
        return generation
    }

    func deactivate() {
        registration = nil
        backend.unregister()
        backend.removeHandler()
    }
}

/// Narrow C-call boundary lets deterministic tests exercise the real decoder without registering keys.
@MainActor
struct CarbonHotKeyCalls {
    var install: ([EventTypeSpec], EventHandlerUPP, UnsafeMutableRawPointer, inout EventHandlerRef?) -> OSStatus
    var register: (UInt32, UInt32, EventHotKeyID, UInt32, inout EventHotKeyRef?) -> OSStatus
    var unregister: (EventHotKeyRef) -> OSStatus
    var remove: (EventHandlerRef) -> OSStatus

    static let system = CarbonHotKeyCalls(
        install: { types, handler, context, output in
            types.withUnsafeBufferPointer {
                InstallEventHandler(GetApplicationEventTarget(), handler, $0.count, $0.baseAddress, context, &output)
            }
        },
        register: { keyCode, modifiers, id, options, output in
            RegisterEventHotKey(keyCode, modifiers, id, GetApplicationEventTarget(), options, &output)
        },
        unregister: { UnregisterEventHotKey($0) },
        remove: { RemoveEventHandler($0) }
    )
}

@MainActor
final class NativeCarbonHotKeyBackend: CarbonHotKeyBackend {
    private let calls: CarbonHotKeyCalls
    private var handler: EventHandlerRef?
    private var hotKey: EventHotKeyRef?
    private var context: UnsafeMutableRawPointer?

    init(calls: CarbonHotKeyCalls = .system) { self.calls = calls }

    func install(_ receive: @escaping @MainActor (CarbonHotKeyEvent) -> Bool) throws {
        guard handler == nil, hotKey == nil, context == nil else { throw CarbonHotKey.Failure.cleanupPending }
        let context = Unmanaged.passRetained(CarbonHotKeyContext(receive: receive)).toOpaque()
        self.context = context
        let types = [
            EventTypeSpec(eventClass: UInt32(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: UInt32(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
        ]
        let status = calls.install(types, carbonHotKeyHandler, context, &handler)
        guard status == noErr else { throw CarbonHotKey.Failure.native(status) }
        guard handler != nil else { throw CarbonHotKey.Failure.missingResource }
    }

    func register(_ chord: CarbonHotKey.Chord, signature: UInt32, id: UInt32) throws {
        let status = calls.register(chord.keyCode, chord.modifiers, EventHotKeyID(signature: signature, id: id), UInt32(kEventHotKeyExclusive), &hotKey)
        guard status == noErr else { throw CarbonHotKey.Failure.native(status) }
        guard hotKey != nil else { throw CarbonHotKey.Failure.missingResource }
    }

    func unregister() {
        if let hotKey, calls.unregister(hotKey) == noErr { self.hotKey = nil }
    }

    func removeHandler() {
        if let context { Unmanaged<CarbonHotKeyContext>.fromOpaque(context).takeUnretainedValue().receive = nil }
        if let handler {
            // Retain an inert context if Carbon cannot detach; never leave a dangling C callback.
            guard calls.remove(handler) == noErr else { return }
            self.handler = nil
        }
        if let context {
            Unmanaged<CarbonHotKeyContext>.fromOpaque(context).release()
            self.context = nil
        }
    }
}

@MainActor
private final class CarbonHotKeyContext {
    var receive: (@MainActor (CarbonHotKeyEvent) -> Bool)?
    init(receive: @escaping @MainActor (CarbonHotKeyEvent) -> Bool) { self.receive = receive }
}

/// Carbon application handlers run on the main event loop; no Task may reorder press/release.
private let carbonHotKeyHandler: EventHandlerUPP = { _, event, context in
    guard Thread.isMainThread, let event, let context else { return OSStatus(eventNotHandledErr) }
    let eventClass = GetEventClass(event)
    let kind = GetEventKind(event)
    guard eventClass == UInt32(kEventClassKeyboard),
          [UInt32(kEventHotKeyPressed), UInt32(kEventHotKeyReleased)].contains(kind) else {
        return OSStatus(eventNotHandledErr)
    }
    var id = EventHotKeyID()
    var actualSize = 0
    guard GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, &actualSize, &id) == noErr,
          actualSize == MemoryLayout<EventHotKeyID>.size else { return OSStatus(eventNotHandledErr) }
    let receiver = Unmanaged<CarbonHotKeyContext>.fromOpaque(context).takeUnretainedValue()
    let decoded = CarbonHotKeyEvent(eventClass: eventClass, kind: kind, signature: id.signature, id: id.id)
    return MainActor.assumeIsolated {
        receiver.receive?(decoded) == true ? noErr : OSStatus(eventNotHandledErr)
    }
}
