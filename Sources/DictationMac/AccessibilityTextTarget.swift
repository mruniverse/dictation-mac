import AppKit
import ApplicationServices
import Carbon
import DictationCore

// Experimental insertion into a TextEdit document (issue #12, pilot). One direct write of
// AXSelectedText to the text area that had the focus when the held shortcut was accepted, after
// revalidating process, window, field and caret. No synthetic keys, no clipboard, no activation of
// another app, no preference changes. Only identity, role and selection attributes are read; the
// document is never read, except the range just written, to confirm it.

/// Result of reading one attribute: missing is evidence of absence, a failure is not.
enum AccessibilityRead<Value: Equatable>: Equatable {
    case value(Value)
    case absent
    case failed
}

/// UTF-16 range, as Accessibility reports text ranges.
struct AccessibilityTextRange: Equatable {
    let location: Int
    let length: Int
}

/// The process that owns the focus: identity only, never a window title, document name or text.
struct AccessibilityProcess: Equatable {
    let pid: pid_t
    let bundleIdentifier: String?
    let launchDate: Date?
}

/// Opaque accessibility element; compared only through `AccessibilityBackend.isSame`.
struct AccessibilityElement {
    let object: AnyObject
}

enum AccessibilityElementAttribute {
    case focusedWindow, focusedUIElement, window
}

/// The only string attributes ever read: no value, title, description or help.
enum AccessibilityStringAttribute {
    case role, subrole
}

enum AccessibilityWriteStatus: Equatable {
    case success
    /// Refused before anything was written.
    case rejected
    /// Messaging failed or timed out: the app may or may not have written.
    case uncertain
}

/// The small port over the Accessibility API, so the policy is testable without TCC or another app.
@MainActor
protocol AccessibilityBackend: AnyObject {
    /// Never prompts.
    func isTrusted() -> Bool
    /// Opens the system's Accessibility request; only from an explicit click.
    func requestTrust()
    func isSecureInputEnabled() -> Bool
    /// The app that receives key events, according to the workspace.
    func frontmostProcess() -> pid_t?
    /// The application that owns the focus, according to Accessibility.
    func focusedApplication() -> AccessibilityElement?
    func process(_ pid: pid_t) -> AccessibilityProcess?
    func processIdentifier(of element: AccessibilityElement) -> pid_t?
    func element(_ attribute: AccessibilityElementAttribute, of element: AccessibilityElement) -> AccessibilityElement?
    func string(_ attribute: AccessibilityStringAttribute, of element: AccessibilityElement) -> AccessibilityRead<String>
    func isSelectedTextSettable(_ element: AccessibilityElement) -> Bool?
    func selectedRange(of element: AccessibilityElement) -> AccessibilityTextRange?
    func setSelectedText(_ text: String, of element: AccessibilityElement) -> AccessibilityWriteStatus
    /// Reads exactly `range`; nil when unsupported or failed.
    func string(in range: AccessibilityTextRange, of element: AccessibilityElement) -> String?
    func isSame(_ a: AccessibilityElement, _ b: AccessibilityElement) -> Bool
}

/// TextEdit's document text area as the destination of one held-shortcut session. `lock()` captures
/// the focused target at the accepted press; `insert` consumes it, revalidates everything and writes
/// once; `release` is idempotent. A newer lock supersedes an older one. Fails closed without evidence.
@MainActor
final class AccessibilityTextTarget: TextInsertionTarget {
    /// Exclusively TextEdit. Terminals, TUIs and REPLs stay on preview/copy.
    static let allowedBundleIdentifiers: Set<String> = ["com.apple.TextEdit"]

    private struct Target {
        let process: AccessibilityProcess
        let window: AccessibilityElement
        let field: AccessibilityElement
        let caret: Int
    }

    private let backend: AccessibilityBackend
    private var held: (token: UUID, target: Target)?

    init(backend: AccessibilityBackend) {
        self.backend = backend
    }

    /// The process of the lock currently held, if any.
    var lockedProcessIdentifier: pid_t? { held?.target.process.pid }

    func lock() -> TextInsertionLock? {
        held = nil
        guard let target = observe() else { return nil }
        let lock = TextInsertionLock(token: UUID())
        held = (lock.token, target)
        return lock
    }

    func insert(_ text: String, into lock: TextInsertionLock) -> TextInsertionResult {
        guard let current = held, current.token == lock.token else { return .notInserted }
        // Consumed before any attempt: whatever happens next, there is no second one.
        held = nil
        let expected = current.target
        guard !text.isEmpty, let now = observe(), matches(now, expected) else { return .notInserted }
        // Last checks right before the single write; nothing else is read in between.
        guard backend.isTrusted(), !backend.isSecureInputEnabled() else { return .notInserted }
        switch backend.setSelectedText(text, of: now.field) {
        case .rejected: return .notInserted
        case .uncertain: return .unconfirmed
        case .success: break
        }
        let length = text.utf16.count
        guard backend.selectedRange(of: now.field) == AccessibilityTextRange(location: expected.caret + length, length: 0) else {
            return .unconfirmed
        }
        let written = AccessibilityTextRange(location: expected.caret, length: length)
        if let read = backend.string(in: written, of: now.field), read != text { return .unconfirmed }
        return .inserted
    }

    func release(_ lock: TextInsertionLock) {
        if held?.token == lock.token { held = nil }
    }

    /// Reads the focused target; nil unless every check passes. Stops at the first missing evidence,
    /// so another app is never inspected beyond its identity.
    private func observe() -> Target? {
        guard backend.isTrusted(), !backend.isSecureInputEnabled(),
              let app = backend.focusedApplication(),
              let pid = backend.processIdentifier(of: app), pid > 0,
              backend.frontmostProcess() == pid,
              let process = backend.process(pid), process.pid == pid, process.launchDate != nil,
              let bundle = process.bundleIdentifier, Self.allowedBundleIdentifiers.contains(bundle)
        else { return nil }

        guard let window = backend.element(.focusedWindow, of: app),
              backend.processIdentifier(of: window) == pid,
              backend.string(.role, of: window) == .value(kAXWindowRole),
              backend.string(.subrole, of: window) == .value(kAXStandardWindowSubrole),
              let field = backend.element(.focusedUIElement, of: app),
              backend.processIdentifier(of: field) == pid,
              backend.string(.role, of: field) == .value(kAXTextAreaRole)
        else { return nil }

        switch backend.string(.subrole, of: field) {
        case .absent: break
        case let .value(subrole) where subrole != kAXSecureTextFieldSubrole: break
        case .value, .failed: return nil
        }

        guard let fieldWindow = backend.element(.window, of: field), backend.isSame(fieldWindow, window),
              backend.isSelectedTextSettable(field) == true,
              let selection = backend.selectedRange(of: field), selection.location >= 0, selection.length == 0
        else { return nil }
        return Target(process: process, window: window, field: field, caret: selection.location)
    }

    private func matches(_ now: Target, _ expected: Target) -> Bool {
        now.process == expected.process
            && backend.isSame(now.window, expected.window)
            && backend.isSame(now.field, expected.field)
            && now.caret == expected.caret
    }
}

/// The real Accessibility API, bounded by short messaging timeouts.
@MainActor
final class NativeAccessibilityBackend: AccessibilityBackend {
    /// Applies to every read of this process (set on the system-wide element).
    static let readTimeout: Float = 0.5
    static let writeTimeout: Float = 1.0

    private var timeoutInstalled = false

    func isTrusted() -> Bool { AXIsProcessTrusted() }

    func requestTrust() {
        // The documented value of kAXTrustedCheckOptionPrompt; the imported global is not concurrency-safe.
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    func isSecureInputEnabled() -> Bool { IsSecureEventInputEnabled() }

    func frontmostProcess() -> pid_t? { NSWorkspace.shared.frontmostApplication?.processIdentifier }

    func focusedApplication() -> AccessibilityElement? {
        let systemWide = AXUIElementCreateSystemWide()
        if !timeoutInstalled {
            timeoutInstalled = AXUIElementSetMessagingTimeout(systemWide, Self.readTimeout) == .success
        }
        guard timeoutInstalled else { return nil }
        return copyElement(systemWide, kAXFocusedApplicationAttribute)
    }

    func process(_ pid: pid_t) -> AccessibilityProcess? {
        guard let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated else { return nil }
        return AccessibilityProcess(pid: pid, bundleIdentifier: app.bundleIdentifier, launchDate: app.launchDate)
    }

    func processIdentifier(of element: AccessibilityElement) -> pid_t? {
        var pid: pid_t = 0
        guard let element = Self.native(element), AXUIElementGetPid(element, &pid) == .success, pid > 0 else { return nil }
        return pid
    }

    func element(_ attribute: AccessibilityElementAttribute, of element: AccessibilityElement) -> AccessibilityElement? {
        guard let element = Self.native(element) else { return nil }
        let name = switch attribute {
        case .focusedWindow: kAXFocusedWindowAttribute
        case .focusedUIElement: kAXFocusedUIElementAttribute
        case .window: kAXWindowAttribute
        }
        return copyElement(element, name)
    }

    func string(_ attribute: AccessibilityStringAttribute, of element: AccessibilityElement) -> AccessibilityRead<String> {
        guard let element = Self.native(element) else { return .failed }
        let name = switch attribute {
        case .role: kAXRoleAttribute
        case .subrole: kAXSubroleAttribute
        }
        var value: CFTypeRef?
        switch AXUIElementCopyAttributeValue(element, name as CFString, &value) {
        case .success: return (value as? String).map { .value($0) } ?? .failed
        case .noValue, .attributeUnsupported: return .absent
        default: return .failed
        }
    }

    func isSelectedTextSettable(_ element: AccessibilityElement) -> Bool? {
        var settable: DarwinBoolean = false
        guard let element = Self.native(element),
              AXUIElementIsAttributeSettable(element, kAXSelectedTextAttribute as CFString, &settable) == .success
        else { return nil }
        return settable.boolValue
    }

    func selectedRange(of element: AccessibilityElement) -> AccessibilityTextRange? {
        var value: CFTypeRef?
        guard let element = Self.native(element),
              AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID()
        else { return nil }
        let range = unsafeDowncast(value, to: AXValue.self)
        var cfRange = CFRange()
        guard AXValueGetType(range) == .cfRange, AXValueGetValue(range, .cfRange, &cfRange) else { return nil }
        return AccessibilityTextRange(location: cfRange.location, length: cfRange.length)
    }

    func setSelectedText(_ text: String, of element: AccessibilityElement) -> AccessibilityWriteStatus {
        guard let element = Self.native(element) else { return .rejected }
        guard AXUIElementSetMessagingTimeout(element, Self.writeTimeout) == .success else { return .rejected }
        // Back to the global read timeout afterwards (0 means "use the global value").
        defer { _ = AXUIElementSetMessagingTimeout(element, 0) }
        return Self.writeStatus(AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFString))
    }

    func string(in range: AccessibilityTextRange, of element: AccessibilityElement) -> String? {
        var cfRange = CFRange(location: range.location, length: range.length)
        var value: CFTypeRef?
        guard let element = Self.native(element), let parameter = AXValueCreate(.cfRange, &cfRange),
              AXUIElementCopyParameterizedAttributeValue(
                  element, kAXStringForRangeParameterizedAttribute as CFString, parameter, &value
              ) == .success
        else { return nil }
        return value as? String
    }

    func isSame(_ a: AccessibilityElement, _ b: AccessibilityElement) -> Bool {
        guard let a = Self.native(a), let b = Self.native(b) else { return false }
        return CFEqual(a, b)
    }

    /// Only errors raised before the app could act count as "not written"; anything else is uncertain.
    static func writeStatus(_ error: AXError) -> AccessibilityWriteStatus {
        switch error {
        case .success: .success
        case .attributeUnsupported, .illegalArgument, .invalidUIElement, .apiDisabled, .notImplemented: .rejected
        default: .uncertain
        }
    }

    private func copyElement(_ element: AXUIElement, _ attribute: String) -> AccessibilityElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID()
        else { return nil }
        return AccessibilityElement(object: value)
    }

    private static func native(_ element: AccessibilityElement) -> AXUIElement? {
        guard CFGetTypeID(element.object) == AXUIElementGetTypeID() else { return nil }
        return unsafeDowncast(element.object, to: AXUIElement.self)
    }
}

/// The menu's experimental TextEdit insertion, wired to the capture controller's hooks. Off at every
/// launch; turned on only by a click, and only with Accessibility already granted (the click may open
/// the system request instead). The toggle is ignored while a session runs. Another app's activation,
/// the first-send question, suspension or quitting invalidate the target; preview and Copiar stay.
@MainActor
final class TextEditInsertionPilot {
    enum OffReason: Equatable {
        case needsAccessibility, suspended
    }

    enum Status: Equatable {
        /// `nil` until something turned it off in this run.
        case off(OffReason?)
        case on
    }

    private(set) var status = Status.off(nil)
    /// Of the last finished session; describes the attempt, never its text.
    private(set) var lastResult: TextInsertionResult?

    private let backend: AccessibilityBackend
    private let target: AccessibilityTextTarget
    private let coordinator: TextInsertionCoordinator
    private weak var controller: CaptureController?
    private var onUpdate: (@MainActor () -> Void)?

    init(backend: AccessibilityBackend = NativeAccessibilityBackend()) {
        self.backend = backend
        target = AccessibilityTextTarget(backend: backend)
        coordinator = TextInsertionCoordinator(target: target)
    }

    var isEnabled: Bool { coordinator.isEnabled }
    var lockedProcessIdentifier: pid_t? { target.lockedProcessIdentifier }

    /// Takes over the controller's session hooks.
    func attach(to controller: CaptureController, onUpdate: @escaping @MainActor () -> Void) {
        self.controller = controller
        self.onUpdate = onUpdate
        controller.onPushToTalkAccepted = { [weak self] id in self?.sessionAccepted(id) }
        controller.onFinish = { [weak self] id, origin, outcome in self?.sessionFinished(id, origin: origin, outcome: outcome) }
    }

    /// The menu item. Turning on without Accessibility asks the system instead and stays off.
    func toggle() {
        guard controller?.phase ?? .idle == .idle else { return }
        if coordinator.isEnabled { return disable() }
        guard backend.isTrusted() else {
            backend.requestTrust()
            return settle(.off(.needsAccessibility))
        }
        coordinator.setEnabled(true)
        settle(.on)
    }

    /// Suspension, quit or the menu: releases any target; nothing turns it on again by itself.
    func disable(_ reason: OffReason? = nil) {
        coordinator.setEnabled(false)
        if status == .on { status = .off(reason) }
        onUpdate?()
    }

    /// Another app took the focus. The locked app itself (e.g. a notification queued before the
    /// press) leaves the target alone; revalidation still checks it before writing.
    func applicationActivated(pid: pid_t?) {
        guard let pid, pid == target.lockedProcessIdentifier else { return coordinator.invalidate() }
    }

    /// Before the first-send question, which takes the focus.
    func invalidate() { coordinator.invalidate() }

    var menuStatus: String {
        switch status {
        case .off(nil): "Inserção no TextEdit (experimental): desativada"
        case .off(.needsAccessibility):
            "Inserção no TextEdit: autorize o app em Ajustes do Sistema › Privacidade e Segurança › Acessibilidade e ative de novo"
        case .off(.suspended): "Inserção no TextEdit desativada pela suspensão — ative de novo para usar"
        case .on: "Inserção no TextEdit: ativa — só no texto de um documento do TextEdit; outros apps ficam na prévia"
        }
    }

    var resultStatus: String? {
        switch lastResult {
        case nil: nil
        case .inserted: "Inserido no TextEdit"
        case .unconfirmed: "Inserção no TextEdit não confirmada — confira o documento; Copiar continua disponível"
        case .notInserted: "Não inserido: o destino mudou ou não pôde ser verificado — use Copiar transcrição"
        }
    }

    private func sessionAccepted(_ id: UUID) {
        lastResult = nil
        guard coordinator.isEnabled, let lock = target.lock() else { return }
        coordinator.bind(lock, to: id)
    }

    private func sessionFinished(_ id: UUID, origin: CaptureController.Origin, outcome: Outcome) {
        let result = coordinator.finish(session: id, origin: origin, outcome: outcome)
        if result == nil, coordinator.isEnabled, origin == .pushToTalk, case .transcribed = outcome {
            lastResult = .notInserted
        } else {
            lastResult = result
        }
        onUpdate?()
    }

    private func settle(_ next: Status) {
        status = next
        onUpdate?()
    }
}
