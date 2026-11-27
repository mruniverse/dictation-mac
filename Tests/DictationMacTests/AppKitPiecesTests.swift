import AppKit
import DictationCore
@testable import DictationMac
import XCTest

/// AppKit pieces of the app, built and exercised without showing any window.
@MainActor
final class MainMenuTests: XCTestCase {
    private func item(_ menu: NSMenu, _ action: String) -> NSMenuItem? {
        menu.items.compactMap(\.submenu).flatMap(\.items).first { $0.action == NSSelectorFromString(action) }
    }

    func testEditMenuGivesTextFieldsTheStandardShortcuts() throws {
        let menu = MainMenu.make()
        let expected: [(String, String, NSEvent.ModifierFlags)] = [
            ("paste:", "v", [.command]), ("copy:", "c", [.command]), ("cut:", "x", [.command]),
            ("selectAll:", "a", [.command]), ("undo:", "z", [.command]), ("redo:", "z", [.command, .shift]),
        ]
        for (action, key, modifiers) in expected {
            let found = try XCTUnwrap(item(menu, action), action)
            XCTAssertEqual(found.keyEquivalent, key, action)
            XCTAssertEqual(found.keyEquivalentModifierMask, modifiers, action)
            XCTAssertNil(found.target, "\(action) must reach the first responder, i.e. the focused field")
        }
    }

    func testLaunchConfigurationInstallsTheEditMenu() throws {
        let app = NSApplication.shared
        app.mainMenu = nil

        DictationMacApp.configure(app)

        let menu = try XCTUnwrap(app.mainMenu)
        XCTAssertEqual(item(menu, "paste:")?.keyEquivalent, "v")
    }
}

@MainActor
final class CloudDialogsTests: XCTestCase {
    func testConsentTextSaysTheAutomaticStopAlsoSends() {
        let text = CloudDialogs.consentText(maxDuration: CaptureLimits().maxDuration)

        XCTAssertTrue(text.contains("uma gravação manual é enviada ao Parar ou pela parada automática"), text)
        XCTAssertTrue(text.contains("atingir 30 s"), text)
        XCTAssertTrue(text.contains("soltar Ctrl+Shift+letra antes de 25 s envia o clipe"), text)
        XCTAssertTrue(text.contains("alcançar esse prazo descarta o áudio sem envio"), text)
        XCTAssertTrue(text.contains("api.openai.com"))
        XCTAssertTrue(text.contains("à parte de qualquer assinatura do ChatGPT"))
        XCTAssertTrue(
            CloudDialogs.consentText(maxDuration: 45).contains("ao atingir 45 s"),
            "the limit in the text is the capture limit"
        )
    }

    func testPlainReturnIsNotAnAuthorizationToSendPaidAudio() {
        _ = NSApplication.shared
        let alert = CloudDialogs.firstSendAlert(duration: 2.0)
        alert.layout()

        XCTAssertTrue(alert.buttons[0].keyEquivalent.isEmpty)
        XCTAssertFalse(alert.window.defaultButtonCell === alert.buttons[0].cell)
    }

    func testFirstSendAlertNamesTheClipAndEscapeDiscards() {
        let alert = CloudDialogs.firstSendAlert(duration: 2.0)

        XCTAssertEqual(alert.buttons.map(\.title), ["Enviar", "Descartar áudio"])
        XCTAssertEqual(alert.buttons[1].keyEquivalent, "\u{1b}")
        XCTAssertTrue(alert.informativeText.contains("o áudio de 2,0 s"))
    }
}

/// The first-send question answers through its own target, not through a modal loop.
@MainActor
final class FirstSendPromptTests: XCTestCase {
    override func setUp() async throws {
        _ = NSApplication.shared // button actions are dispatched through NSApp
    }

    func testSendAnswersYesOnce() {
        var answers: [Bool] = []
        let prompt = FirstSendPrompt.make(duration: 2.0) { answers.append($0) }

        prompt.alert.buttons[0].performClick(nil)
        prompt.alert.buttons[0].performClick(nil)
        prompt.alert.buttons[1].performClick(nil)

        XCTAssertEqual(answers, [true])
    }

    func testDiscardAnswersNo() {
        var answers: [Bool] = []
        let prompt = FirstSendPrompt.make(duration: 2.0) { answers.append($0) }

        prompt.alert.buttons[1].performClick(nil)

        XCTAssertEqual(answers, [false])
    }

    func testWithdrawnPromptIgnoresLaterClicks() {
        var answers: [Bool] = []
        let prompt = FirstSendPrompt.make(duration: 2.0) { answers.append($0) }

        prompt.close()
        prompt.alert.buttons[0].performClick(nil)

        XCTAssertEqual(answers, [])
        XCTAssertFalse(prompt.alert.window.isVisible)
    }
}
