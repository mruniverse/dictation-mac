import AppKit
import DictationCore

/// Dialogs of the cloud transcription settings. Texts name the destination and the cost; no dialog
/// ever shows, copies or logs the API key.
@MainActor
enum CloudDialogs {
    static let destinationText = "OpenAI (api.openai.com, modelo \(OpenAITranscriber.model))"

    /// Secure entry. Returns nil when the user cancels; an invalid key is reported without echoing it.
    static func askForAPIKey() -> OpenAIAPIKey? {
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 340, height: 24))
        field.placeholderString = "Cole a chave aqui"
        let alert = NSAlert()
        alert.messageText = "Chave de API da OpenAI"
        alert.informativeText = """
            A chave fica no Keychain deste Mac e, nesta execução, em memória; nunca aparece no \
            menu nem em logs. Nas próximas execuções, use “Carregar chave salva do Keychain”.

            Salvar a chave não autoriza o envio de áudio: a autorização é um passo separado, \
            em “Autorizar envio à OpenAI…”.
            """
        alert.accessoryView = field
        alert.addButton(withTitle: "Salvar")
        alert.addButton(withTitle: "Cancelar")
        alert.window.initialFirstResponder = field
        defer { field.stringValue = "" }
        guard runModal(alert) == .alertFirstButtonReturn else { return nil }
        guard let key = OpenAIAPIKey(field.stringValue) else {
            notify("Chave não salva", "A chave está vazia ou tem espaços ou caracteres inválidos.")
            return nil
        }
        return key
    }

    /// Every way a recording ends with audio — Parar or the automatic stop — leads to an upload.
    static func consentText(maxDuration: TimeInterval) -> String {
        """
        Com a autorização, cada gravação encerrada em Parar — ou pela parada automática, ao \
        atingir \(Int(maxDuration)) s — é enviada para transcrição à \(destinationText), com a \
        sua chave de API.

        Custo: cobrado pela OpenAI na conta da chave de API, à parte de qualquer assinatura do \
        ChatGPT.

        O áudio não é salvo neste Mac. O tratamento e a retenção pelo provedor seguem a política \
        de dados da API da OpenAI.

        O primeiro envio ainda pedirá confirmação. Você pode revogar a autorização neste menu a \
        qualquer momento.
        """
    }

    /// Explicit consent, separate from the key: destination, cost and what happens to the audio.
    static func askForConsent(maxDuration: TimeInterval) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Autorizar o envio de áudio à OpenAI?"
        alert.informativeText = consentText(maxDuration: maxDuration)
        alert.addButton(withTitle: "Autorizar envio")
        alert.addButton(withTitle: "Cancelar")
        return runModal(alert) == .alertFirstButtonReturn
    }

    static func firstSendAlert(duration: TimeInterval) -> NSAlert {
        let seconds = String(format: "%.1f", duration).replacingOccurrences(of: ".", with: ",")
        let alert = NSAlert()
        alert.messageText = "Enviar esta gravação à OpenAI?"
        alert.informativeText = """
            Primeiro envio desde a autorização: o áudio de \(seconds) s vai para a \
            \(destinationText) e é cobrado na conta da sua chave de API.

            Os próximos envios não pedirão confirmação até você revogar a autorização. Sem \
            resposta dentro do prazo de processamento, o áudio é descartado.
            """
        let send = alert.addButton(withTitle: "Enviar")
        let discard = alert.addButton(withTitle: "Descartar áudio")
        alert.layout()
        // The prompt may appear while the user is typing in another app. Return must not upload audio.
        send.keyEquivalent = ""
        alert.window.defaultButtonCell = nil
        discard.keyEquivalent = "\u{1b}"
        alert.window.initialFirstResponder = discard
        return alert
    }

    /// Information that needs no answer; shown without a modal loop, so it is safe from any callback.
    static func notify(_ title: String, _ detail: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.addButton(withTitle: "OK")
        FloatingAlert(alert) { _ in }.show()
    }

    /// Only for the settings dialogs, opened from a menu item that is enabled while no session
    /// runs, so nothing time-bound waits on the main queue meanwhile. Never call it from a
    /// dispatched block or a session callback: a modal loop there keeps the main queue from
    /// draining until the user answers.
    private static func runModal(_ alert: NSAlert) -> NSApplication.ModalResponse {
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal()
    }
}

/// An alert shown without a modal loop. `runModal` started from a main-queue block keeps the main
/// queue from draining until the user answers: the processing deadline, MainActor tasks and the
/// withdrawal never run, and a late answer still counts. This window leaves the run loop alone;
/// it answers once, and `close()` makes any later click a no-op.
@MainActor
final class FloatingAlert: NSObject {
    /// Alerts on screen, kept alive until answered or closed: buttons hold their target weakly.
    private static var shown: [FloatingAlert] = []

    let alert: NSAlert
    private var onAnswer: (@MainActor (NSApplication.ModalResponse) -> Void)?

    init(_ alert: NSAlert, onAnswer: @escaping @MainActor (NSApplication.ModalResponse) -> Void) {
        self.alert = alert
        self.onAnswer = onAnswer
        super.init()
        for button in alert.buttons {
            button.target = self
            button.action = #selector(buttonPressed(_:))
        }
    }

    func show() {
        guard onAnswer != nil else { return }
        Self.shown.append(self)
        alert.layout()
        let window = alert.window
        window.level = .floating
        // An alert window is a panel, which hides when the app loses focus; keep the question visible.
        window.hidesOnDeactivate = false
        window.center()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    /// Withdraws the alert: it disappears and later clicks are ignored. Idempotent.
    func close() {
        onAnswer = nil
        alert.window.orderOut(nil)
        Self.shown.removeAll { $0 === self }
    }

    @objc private func buttonPressed(_ sender: NSButton) {
        guard let onAnswer, let index = alert.buttons.firstIndex(of: sender) else { return }
        close()
        onAnswer(NSApplication.ModalResponse(rawValue: NSApplication.ModalResponse.alertFirstButtonReturn.rawValue + index))
    }
}

/// First-send confirmation: `ask` shows a floating alert and returns at once; the handle it returns
/// withdraws the alert (deadline, cancel, revocation, key removal) so a later click is never an answer.
@MainActor
enum FirstSendPrompt {
    static func ask(
        duration: TimeInterval,
        reply: @escaping @Sendable @MainActor (Bool) -> Void
    ) -> TranscriptionCancellation {
        let prompt = make(duration: duration, reply: reply)
        prompt.show()
        return TranscriptionCancellation { prompt.close() }
    }

    static func make(duration: TimeInterval, reply: @escaping @Sendable @MainActor (Bool) -> Void) -> FloatingAlert {
        FloatingAlert(CloudDialogs.firstSendAlert(duration: duration)) { reply($0 == .alertFirstButtonReturn) }
    }
}
