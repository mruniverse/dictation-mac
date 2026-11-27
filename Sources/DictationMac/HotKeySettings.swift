import AVFoundation
import Carbon
import DictationCore

/// The fixed, short list of Ctrl+Shift+letter combinations the menu offers.
enum PushToTalkShortcut: String, CaseIterable, Sendable {
    case d = "D", g = "G", j = "J", k = "K"

    var title: String { "Ctrl+Shift+" + rawValue }

    var chord: CarbonHotKey.Chord {
        let key = switch self {
        case .d: kVK_ANSI_D
        case .g: kVK_ANSI_G
        case .j: kVK_ANSI_J
        case .k: kVK_ANSI_K
        }
        return CarbonHotKey.Chord(keyCode: UInt32(key), modifiers: UInt32(controlKey | shiftKey))
    }
}

/// Microphone authorization as read, never requested, when the shortcut is enabled.
enum MicrophoneAccess: Equatable, Sendable {
    case authorized
    case notDetermined
    case denied

    /// Reads the status only; the system prompt stays tied to Iniciar.
    static func current() -> MicrophoneAccess {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: .authorized
        case .notDetermined: .notDetermined
        default: .denied
        }
    }
}

/// The menu's push-to-talk: one exclusive Ctrl+Shift+letter bound to the capture controller. Off at
/// every launch; enabled only by the user, and only once the microphone is already authorized. The
/// first press after enabling only arms. Presses are ignored while a settings dialog or the
/// first-send question is open and under Secure Input; a release then discards the held clip.
/// Disabling, suspension, quitting or choosing another letter cancel the held session and
/// unregister the key; nothing enables it again on its own.
@MainActor
final class HotKeySettings {
    enum OffReason: Equatable, Sendable {
        case disabled, suspended, reconfigured, microphoneNotDetermined, microphoneDenied, conflict, failed
    }

    enum Status: Equatable, Sendable {
        /// `nil` until the user tries to enable it in this run.
        case off(OffReason?)
        case active
    }

    private(set) var shortcut = PushToTalkShortcut.d
    private(set) var status = Status.off(nil)
    /// Called after every change here, including each delivered key event.
    var onChange: (() -> Void)?
    let maximumHold: TimeInterval

    private let capture: CaptureController
    private let hotKey: CarbonHotKey
    private var gesture: PushToTalk!
    private let microphone: @MainActor () -> MicrophoneAccess
    private let secureInput: @MainActor () -> Bool
    private let firstSendOpen: @MainActor () -> Bool
    private var openDialogs = 0

    /// `now` must be the controller's monotonic clock.
    init(
        capture: CaptureController,
        scheduler: Scheduler,
        now: @escaping @MainActor () -> ContinuousClock.Instant = { ContinuousClock.now },
        backend: CarbonHotKeyBackend = NativeCarbonHotKeyBackend(),
        microphone: @escaping @MainActor () -> MicrophoneAccess = MicrophoneAccess.current,
        secureInput: @escaping @MainActor () -> Bool = { IsSecureEventInputEnabled() },
        firstSendOpen: @escaping @MainActor () -> Bool = { FirstSendPrompt.isOpen },
        maximumHold: TimeInterval = 25
    ) {
        self.capture = capture
        hotKey = CarbonHotKey(backend: backend)
        self.microphone = microphone
        self.secureInput = secureInput
        self.firstSendOpen = firstSendOpen
        self.maximumHold = maximumHold
        gesture = PushToTalk(
            capture: capture, scheduler: scheduler, maximumHold: maximumHold, now: now,
            blocked: { [weak self] in self?.isBlocked ?? true }
        )
    }

    /// Read at each press and release; the release is still latched.
    var isBlocked: Bool { openDialogs > 0 || firstSendOpen() || secureInput() }

    func enable() {
        guard status != .active, capture.phase == .idle else { return }
        switch microphone() {
        case .authorized: break
        case .notDetermined: return settle(.off(.microphoneNotDetermined))
        case .denied: return settle(.off(.microphoneDenied))
        }
        do {
            let generation = try hotKey.activate(chord: shortcut.chord) { [weak self] event, generation in
                self?.deliver(event, generation: generation)
            }
            gesture.activate(registration: generation)
            settle(.active)
        } catch {
            gesture.deactivate()
            settle(.off(Self.isConflict(error) ? .conflict : .failed))
        }
    }

    /// Cancels the held session, then unregisters; each layer invalidates its generation first.
    func disable(_ reason: OffReason = .disabled) {
        if status == .active { status = .off(reason) }
        gesture.deactivate()
        hotKey.deactivate()
        onChange?()
    }

    /// Sleep or session switch: off until the user enables it again.
    func suspend() { disable(.suspended) }

    /// Another letter takes effect only when the user enables the shortcut again.
    func select(_ shortcut: PushToTalkShortcut) {
        guard capture.phase == .idle || capture.origin == .pushToTalk,
              shortcut != self.shortcut else { return }
        disable(.reconfigured)
        self.shortcut = shortcut
        onChange?()
    }

    /// Forward every capture transition, before rendering.
    func captureChanged() { gesture.captureChanged() }

    /// Modal settings dialogs (key, consent, enabling): presses start nothing meanwhile.
    func duringSettingsDialog<T>(_ body: () -> T) -> T {
        openDialogs += 1
        defer { openDialogs -= 1 }
        return body()
    }

    var menuStatus: String {
        let name = shortcut.title
        switch status {
        case .off(nil), .off(.disabled): return "Atalho de gravação: desativado"
        case .off(.suspended): return "Atalho desativado pela suspensão — ative de novo para usar"
        case .off(.reconfigured): return "Combinação trocada para \(name) — ative o atalho de novo para usar"
        case .off(.microphoneNotDetermined):
            return "Atalho não ativado: grave uma vez com Iniciar e permita o microfone"
        case .off(.microphoneDenied):
            return "Atalho não ativado: libere o microfone em Ajustes do Sistema › Privacidade e Segurança › Microfone"
        case .off(.conflict): return "\(name) já está em uso — use Iniciar e Parar"
        case .off(.failed): return "Não foi possível registrar \(name) — use Iniciar e Parar"
        case .active:
            if secureInput() { return "\(name) bloqueado: entrada segura ativa (campo de senha)" }
            if gesture.isPressed { return "\(name) pressionado: solte para encerrar" }
            if gesture.isArmed { return "\(name) pronto: segure para gravar e solte para encerrar" }
            return "\(name) ativo: pressione e solte uma vez para armar (esse toque não grava)"
        }
    }

    private func deliver(_ event: PushToTalkEvent, generation: UUID) {
        gesture.receive(event, registration: generation)
        onChange?()
    }

    private func settle(_ next: Status) {
        status = next
        onChange?()
    }

    private static func isConflict(_ error: Error) -> Bool {
        if case let CarbonHotKey.Failure.native(status) = error { return status == OSStatus(eventHotKeyExistsErr) }
        return false
    }
}
