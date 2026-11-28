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
        keys: KeychainAPIKeyStore(),
        consent: CloudConsent(storage: UserDefaults.standard),
        confirmFirstSend: { FirstSendPrompt.ask(duration: $0, reply: $1) }
    )
    private var settings: CloudSettings { cloud.settings }
    private lazy var controller = CaptureController(
        permission: SystemMicrophonePermission(),
        capture: EngineAudioCapture(inputUID: { [weak self] in self?.inputDeviceSelection.chosen?.uid }),
        scheduler: MainQueueScheduler(),
        transcriber: cloud.transcriber,
        limits: limits
    )
    private lazy var inputDeviceSelection = InputDeviceSelection(storage: .standard)
    private lazy var microphoneMenu = MicrophoneMenu(
        catalog: CoreAudioInputDevices(),
        selection: inputDeviceSelection,
        isIdle: { [weak self] in self?.controller.phase == .idle }
    )
    private lazy var hotKeySettings = HotKeySettings(capture: controller, scheduler: MainQueueScheduler())

    private var statusItem: NSStatusItem?
    private let phaseItem = AppDelegate.infoItem()
    private let outcomeItem = AppDelegate.infoItem()
    private lazy var startItem = actionItem("Iniciar", #selector(startCapture))
    private lazy var stopItem = actionItem("Parar", #selector(stopCapture))
    private lazy var cancelItem = actionItem("Cancelar", #selector(cancelCapture))
    private lazy var copyItem = actionItem("Copiar transcrição", #selector(copyTranscript))
    private let keyStatusItem = AppDelegate.infoItem()
    private let consentStatusItem = AppDelegate.infoItem()
    private let hotKeyStatusItem = AppDelegate.infoItem()
    private lazy var toggleHotKeyItem = actionItem("Ativar atalho global…", #selector(toggleHotKey))
    private lazy var setKeyItem = actionItem("Configurar chave de API…", #selector(setAPIKey))
    private lazy var removeKeyItem = actionItem("Remover chave de API", #selector(removeAPIKey))
    private lazy var grantItem = actionItem("Autorizar envio à OpenAI…", #selector(grantConsent))
    private lazy var revokeItem = actionItem("Revogar autorização de envio", #selector(revokeConsent))
    private lazy var hotKeyMenuItem: NSMenuItem = {
        let item = NSMenuItem(title: "Atalho global (push-to-talk)", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        submenu.delegate = self
        submenu.addItem(hotKeyStatusItem)
        submenu.addItem(toggleHotKeyItem)
        submenu.addItem(.separator())
        hotKeyShortcutItems.forEach(submenu.addItem)
        item.submenu = submenu
        return item
    }()
    private lazy var hotKeyShortcutItems: [NSMenuItem] = PushToTalkShortcut.allCases.enumerated().map { index, shortcut in
        let item = actionItem(shortcut.title, #selector(selectPushToTalkShortcut(_:)))
        item.tag = index
        return item
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let cloudMenu = NSMenu()
        cloudMenu.autoenablesItems = false
        for item in [keyStatusItem, consentStatusItem, .separator(), setKeyItem, removeKeyItem, .separator(), grantItem, revokeItem] {
            cloudMenu.addItem(item)
        }
        let cloudItem = NSMenuItem(title: "Transcrição na nuvem (OpenAI)", action: nil, keyEquivalent: "")
        cloudItem.submenu = cloudMenu

        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        for item in [phaseItem, outcomeItem, .separator(), startItem, stopItem, cancelItem, copyItem, .separator(), hotKeyMenuItem, microphoneMenu.item, .separator(), cloudItem, .separator()] {
            menu.addItem(item)
        }
        menu.addItem(NSMenuItem(title: "Sair", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.menu = menu
        statusItem = item

        controller.onChange = { [weak self] in
            self?.hotKeySettings.captureChanged()
            self?.render()
        }
        settings.onChange = { [weak self] in self?.render() }
        hotKeySettings.onChange = { [weak self] in self?.render() }
        inputDeviceSelection.onChange = { [weak self] in self?.render() }
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.controller.suspend()
                    self?.hotKeySettings.suspend()
                }
            }
        }
        render()
        settings.refreshKeyStatus()
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotKeySettings.disable()
        controller.cancel()
    }

    /// Status values are read-only; the actual Keychain lookup runs off the main thread.
    func menuWillOpen(_ menu: NSMenu) {
        render()
        settings.refreshKeyStatus()
    }

    // MARK: Capture

    @objc private func startCapture() { controller.start() }
    @objc private func stopCapture() { controller.stop() }
    @objc private func cancelCapture() { controller.cancel() }

    @objc private func toggleHotKey() {
        if hotKeySettings.status == .active { hotKeySettings.disable() }
        else if controller.phase == .idle { hotKeySettings.enable() }
    }

    @objc private func selectPushToTalkShortcut(_ sender: NSMenuItem) {
        guard controller.phase == .idle, PushToTalkShortcut.allCases.indices.contains(sender.tag) else { return }
        hotKeySettings.select(PushToTalkShortcut.allCases[sender.tag])
    }

    /// Explicit copy of real provider text only; nothing is copied automatically.
    @objc private func copyTranscript() {
        guard case let .transcribed(text, _) = controller.lastOutcome else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    // MARK: Cloud settings

    @objc private func setAPIKey() {
        guard controller.phase == .idle,
              let key = hotKeySettings.duringSettingsDialog({ CloudDialogs.askForAPIKey() }),
              controller.phase == .idle else { return }
        settings.saveKey(key) { failure in
            if let failure { CloudDialogs.notify("Chave não salva", Self.keychainFailure(failure)) }
        }
    }

    /// Takes effect at once: a clip on its way is discarded unsent; then the item is deleted.
    @objc private func removeAPIKey() {
        settings.removeKey { failure in
            if let failure { CloudDialogs.notify("Chave não removida", Self.keychainFailure(failure)) }
        }
    }

    @objc private func grantConsent() {
        guard controller.phase == .idle, settings.consent.state == .notGranted,
              hotKeySettings.duringSettingsDialog({
                  CloudDialogs.askForConsent(maxDuration: limits.maxDuration, pttMaximumHold: hotKeySettings.maximumHold)
              }),
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
        stopItem.isEnabled = phase == .recording && controller.origin == .manual
        cancelItem.isEnabled = phase != .idle
        hotKeyStatusItem.title = hotKeySettings.menuStatus
        microphoneMenu.refresh()
        toggleHotKeyItem.title = hotKeySettings.status == .active ? "Desativar atalho global" : "Ativar atalho global…"
        toggleHotKeyItem.isEnabled = phase == .idle || hotKeySettings.status == .active
        for (index, shortcut) in PushToTalkShortcut.allCases.enumerated() {
            hotKeyShortcutItems[index].state = hotKeySettings.shortcut == shortcut ? .on : .off
            hotKeyShortcutItems[index].isEnabled = hotKeySettings.status != .active && phase == .idle
        }
        if case .transcribed = controller.lastOutcome { copyItem.isEnabled = true } else { copyItem.isEnabled = false }

        let keyStatus = settings.keyStatus
        keyStatusItem.title = switch keyStatus {
        case .unknown: "Chave de API: verificando o Keychain…"
        case .stored: "Chave de API: guardada no Keychain"
        case .missing: "Chave de API: não configurada"
        case let .unavailable(failure): "Chave de API: Keychain indisponível (código \(failure.status))"
        }
        let state = settings.consent.state
        consentStatusItem.title = switch state {
        case .notGranted: "Envio de áudio: não autorizado"
        case .awaitingFirstSend: "Envio de áudio: autorizado — o 1º envio pede confirmação"
        case .active: "Envio de áudio: autorizado"
        }
        // Settings dialogs run modally, so they open only while no session runs.
        setKeyItem.isEnabled = phase == .idle
        removeKeyItem.isEnabled = keyStatus != .missing
        grantItem.isEnabled = phase == .idle && state == .notGranted
        revokeItem.isEnabled = state != .notGranted
    }

    private static func abbreviated(_ text: String, limit: Int = 90) -> String {
        text.count <= limit ? text : String(text.prefix(limit)) + "…"
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
