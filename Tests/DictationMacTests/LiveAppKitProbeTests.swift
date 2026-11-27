import AppKit
import DictationCore
@testable import DictationMac
import XCTest

/// Real AppKit, real window: opt in with DICTATION_MAC_UI_PROBE=1. The window stays on screen for a
/// fraction of a second; no microphone, keychain, network or privacy permission is involved.
@MainActor
final class LiveAppKitProbeTests: XCTestCase {
    override func setUp() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["DICTATION_MAC_UI_PROBE"] == "1", "opt-in UI probe")
        DictationMacApp.configure(NSApplication.shared)
        // Safety net for a regression to a modal loop: abort it, or the test would wait for a click.
        let guardTimer = Timer(timeInterval: 2, repeats: false) { _ in
            MainActor.assumeIsolated { if NSApp.modalWindow != nil { NSApp.abortModal() } }
        }
        RunLoop.main.add(guardTimer, forMode: .modalPanel)
        RunLoop.main.add(guardTimer, forMode: .default)
    }

    /// Presented from a main-queue block, as the gate does after a key lookup: the processing
    /// deadline (a main-queue timer) and MainActor tasks must still run while the question is on
    /// screen; the deadline withdraws it, and no answer can come afterwards.
    func testDeadlineFiresAndWithdrawsWhileTheQuestionIsOnScreen() async {
        var answers: [Bool] = []
        var waited: TimeInterval?
        var visibleAtDeadline = false
        var taskRan = false
        let withdrawn = expectation(description: "deadline withdrew the question")

        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                let shown = Date()
                let handle = FirstSendPrompt.ask(duration: 2.0) { answers.append($0) }
                Task { @MainActor in taskRan = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    MainActor.assumeIsolated {
                        waited = Date().timeIntervalSince(shown)
                        visibleAtDeadline = Self.questionOnScreen
                        handle.cancel()
                        withdrawn.fulfill()
                    }
                }
            }
        }
        await fulfillment(of: [withdrawn], timeout: 1.5)

        XCTAssertLessThan(waited ?? .infinity, 1.0, "the main queue kept draining while the question was open")
        XCTAssertTrue(visibleAtDeadline, "the question was on screen when the deadline fired")
        XCTAssertTrue(taskRan, "MainActor tasks (permission answer, provider result) kept running")
        XCTAssertFalse(Self.questionOnScreen)
        XCTAssertNil(NSApp.modalWindow)
        XCTAssertEqual(answers, [], "no answer was given, and none can come after withdrawal")
    }

    private static var questionOnScreen: Bool {
        NSApp.windows.contains { $0.isVisible && $0.level == .floating }
    }
}
