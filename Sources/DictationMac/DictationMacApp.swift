import AppKit
import DictationCore

@main
@MainActor
enum DictationMacApp {
    static func main() {
        let app = NSApplication.shared
        configure(app)
        let delegate = AppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }

    /// Menu-bar accessory whose hidden main menu still gives text fields ⌘X, ⌘C, ⌘V and ⌘A.
    static func configure(_ app: NSApplication) {
        app.setActivationPolicy(.accessory)
        app.mainMenu = MainMenu.make()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let limits = CaptureLimits()
    private lazy var cloud = CloudTranscription.openAI(
        keys: keyStore,
        consent: CloudConsent(storage: UserDefaults.standard),
        confirmFirstSend: { FirstSendPrompt.ask(duration: $0, reply: $1) }
    )
    private var settings: CloudSettings { cloud.settings }
    /// The app's Keychain item; replaced only by tests, before the menu is first used.
    var keyStore: any APIKeyStore = KeychainAPIKeyStore()
    private lazy var controller = CaptureController(
        permission: SystemMicrophonePermission(),
        capture: EngineAudioCapture(),
        scheduler: MainQueueScheduler(),
        transcriber: cloud.transcriber,
        limits: limits
    )

    private var statusItem: NSStatusItem?
    private let phaseItem = AppDelegate.infoItem()
    private let outcomeItem = AppDelegate.infoItem()
    private lazy var startItem = actionItem("Iniciar", #selector(startCapture))
    private lazy var stopItem = actionItem("Parar", #selector(stopCapture))
    private lazy var cancelItem = actionItem("Cancelar", #selector(cancelCapture))
    private lazy var copyItem = actionItem("Copiar transcrição", #selector(copyTranscript))
    private let keyStatusItem = AppDelegate.infoItem()
    private let consentStatusItem = AppDelegate.infoItem()
    private lazy var setKeyItem = actionItem("Configurar chave de API…", #selector(setAPIKey))
    private lazy var loadKeyItem = actionItem("Carregar chave salva do Keychain", #selector(loadAPIKey))
    private lazy var removeKeyItem = actionItem("Remover chave de API", #selector(removeAPIKey))
    private lazy var grantItem = actionItem("Autorizar envio à OpenAI…", #selector(grantConsent))
    private lazy var revokeItem = actionItem("Revogar autorização de envio", #selector(revokeConsent))

    func applicationDidFinishLaunching(_ notification: Notification) {
        let cloudMenu = NSMenu()
        cloudMenu.autoenablesItems = false
        for item in [keyStatusItem, consentStatusItem, .separator(), loadKeyItem, setKeyItem, removeKeyItem, .separator(), grantItem, revokeItem] {
            cloudMenu.addItem(item)
        }
        let cloudItem = NSMenuItem(title: "Transcrição na nuvem (OpenAI)", action: nil, keyEquivalent: "")
        cloudItem.submenu = cloudMenu

        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        for item in [phaseItem, outcomeItem, .separator(), startItem, stopItem, cancelItem, copyItem, .separator(), cloudItem, .separator()] {
            menu.addItem(item)
        }
        menu.addItem(NSMenuItem(title: "Sair", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.menu = menu
        statusItem = item

        controller.onChange = { [weak self] in self?.render() }
        settings.onChange = { [weak self] in self?.render() }
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.controller.suspend() }
            }
        }
        render()
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller.cancel()
    }

    /// Shows this run's key status as it is in memory; opening the menu never touches the Keychain.
    func menuWillOpen(_ menu: NSMenu) {
        render()
    }

    // MARK: Capture

    @objc private func startCapture() { controller.start() }
    @objc private func stopCapture() { controller.stop() }
    @objc private func cancelCapture() { controller.cancel() }

    /// Explicit copy of real provider text only; nothing is copied automatically.
    @objc private func copyTranscript() {
        guard case let .transcribed(text, _) = controller.lastOutcome else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    // MARK: Cloud settings

    /// The only read of the saved key: once, on this click, for this run. The system may ask to
    /// allow it; the app never asks for "Sempre Permitir".
    @objc private func loadAPIKey() {
        settings.loadKey { [weak self] failure in
            guard let failure else { return }
            let kept = self?.settings.keyStatus == .loaded ? " A chave já carregada continua em uso nesta execução." : ""
            CloudDialogs.notify("Chave não carregada", Self.keychainFailure(failure) + kept)
        }
    }

    @objc private func setAPIKey() {
        guard controller.phase == .idle, let key = CloudDialogs.askForAPIKey(),
              controller.phase == .idle else { return }
        settings.saveKey(key) { failure in
            if let failure { CloudDialogs.notify("Chave não salva", Self.keychainFailure(failure)) }
        }
    }

    /// Takes effect at once: this run's key is forgotten, consent revoked and a clip on its way
    /// discarded unsent; then the item is deleted.
    @objc private func removeAPIKey() {
        settings.removeKey { failure in
            guard let failure else { return }
            let detail = " Ela já não é usada nesta execução e o envio foi desautorizado."
            CloudDialogs.notify("Chave não removida do Keychain", Self.keychainFailure(failure) + detail)
        }
    }

    @objc private func grantConsent() {
        guard controller.phase == .idle, settings.consent.state == .notGranted,
              CloudDialogs.askForConsent(maxDuration: limits.maxDuration),
              controller.phase == .idle, settings.consent.state == .notGranted else {
            return
        }
        settings.grantConsent()
    }

    /// Takes effect at once: a clip on its way — question, lookup or request — is discarded unsent.
    @objc private func revokeConsent() {
        settings.revokeConsent()
    }

    private static func keychainFailure(_ failure: KeychainError) -> String {
        "O Keychain recusou a operação (código \(failure.status))."
    }

    // MARK: Rendering

    private func render() {
        let phase = controller.phase
        let (symbol, label): (String, String) = switch phase {
        case .idle: ("mic", "Pronto")
        case .awaitingPermission: ("hourglass", "Aguardando permissão do microfone…")
        case .recording: ("record.circle", "Gravando…")
        case .processing: ("hourglass", "Processando…")
        }
        statusItem?.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Dictation Mac: \(label)")
        phaseItem.title = label
        outcomeItem.title = Self.abbreviated(controller.lastOutcome?.message ?? "")
        outcomeItem.isHidden = controller.lastOutcome == nil
        startItem.isEnabled = phase == .idle
        stopItem.isEnabled = phase == .recording
        cancelItem.isEnabled = phase != .idle
        if case .transcribed = controller.lastOutcome { copyItem.isEnabled = true } else { copyItem.isEnabled = false }

        let keyStatus = settings.keyStatus
        keyStatusItem.title = Self.keyStatusTitle(keyStatus, waiting: settings.isWaitingForKeychain)
        let state = settings.consent.state
        consentStatusItem.title = switch state {
        case .notGranted: "Envio de áudio: não autorizado"
        case .awaitingFirstSend: "Envio de áudio: autorizado — o 1º envio pede confirmação"
        case .active: "Envio de áudio: autorizado"
        }
        // Settings dialogs run modally, so they open only while no session runs.
        setKeyItem.isEnabled = phase == .idle
        loadKeyItem.isEnabled = !settings.isWaitingForKeychain
        removeKeyItem.isEnabled = keyStatus != .missing
        grantItem.isEnabled = phase == .idle && state == .notGranted
        revokeItem.isEnabled = state != .notGranted
    }

    private static func abbreviated(_ text: String, limit: Int = 90) -> String {
        text.count <= limit ? text : String(text.prefix(limit)) + "…"
    }

    /// What is in memory for this run; never the result of a Keychain lookup made to draw the menu.
    static func keyStatusTitle(_ status: APIKeyStatus, waiting: Bool) -> String {
        if waiting { return "Chave de API: aguardando o Keychain…" }
        return switch status {
        case .notLoaded: "Chave de API: não carregada nesta execução"
        case .loaded: "Chave de API: carregada nesta execução"
        case .missing: "Chave de API: nenhuma salva no Keychain"
        case let .unavailable(failure): "Chave de API: Keychain não liberou (código \(failure.status))"
        }
    }

    private static func infoItem() -> NSMenuItem {
        let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func actionItem(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }
}
