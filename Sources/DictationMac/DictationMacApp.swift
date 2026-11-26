import AppKit
import DictationCore

@main
@MainActor
enum DictationMacApp {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let controller = CaptureController(
        permission: SystemMicrophonePermission(),
        capture: EngineAudioCapture(),
        scheduler: MainQueueScheduler()
    )
    private var statusItem: NSStatusItem?
    private let phaseItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let outcomeItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private lazy var startItem = actionItem("Iniciar", #selector(startCapture))
    private lazy var stopItem = actionItem("Parar", #selector(stopCapture))
    private lazy var cancelItem = actionItem("Cancelar", #selector(cancelCapture))

    func applicationDidFinishLaunching(_ notification: Notification) {
        let menu = NSMenu()
        menu.autoenablesItems = false
        phaseItem.isEnabled = false
        outcomeItem.isEnabled = false
        for item in [phaseItem, outcomeItem, .separator(), startItem, stopItem, cancelItem, .separator()] {
            menu.addItem(item)
        }
        menu.addItem(NSMenuItem(title: "Sair", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.menu = menu
        statusItem = item

        controller.onChange = { [weak self] in self?.render() }
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

    @objc private func startCapture() { controller.start() }
    @objc private func stopCapture() { controller.stop() }
    @objc private func cancelCapture() { controller.cancel() }

    private func actionItem(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

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
        outcomeItem.title = controller.lastOutcome?.message ?? ""
        outcomeItem.isHidden = controller.lastOutcome == nil
        startItem.isEnabled = phase == .idle
        stopItem.isEnabled = phase == .recording
        cancelItem.isEnabled = phase != .idle
    }
}
