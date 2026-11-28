import DictationCore
import XCTest

@MainActor
final class InputDeviceSelectionTests: XCTestCase {
    private var suite: String!
    private var storage: UserDefaults!

    override func setUp() async throws {
        suite = "InputDeviceSelectionTests-\(UUID().uuidString)"
        storage = try XCTUnwrap(UserDefaults(suiteName: suite))
    }

    override func tearDown() async throws {
        storage.removePersistentDomain(forName: suite)
    }

    func testSystemDefaultIsUsedUntilTheUserChoosesADevice() {
        let selection = InputDeviceSelection(storage: storage)

        XCTAssertNil(selection.chosen)
    }

    func testChoiceSurvivesRelaunchByUIDAndRemembersTheName() {
        InputDeviceSelection(storage: storage).choose(InputDevice(uid: "usb-mic-uid", name: "USB Mic"))

        XCTAssertEqual(InputDeviceSelection(storage: storage).chosen, InputDevice(uid: "usb-mic-uid", name: "USB Mic"))
    }

    func testChoosingTheSystemDefaultForgetsTheDevice() {
        let selection = InputDeviceSelection(storage: storage)
        selection.choose(InputDevice(uid: "usb-mic-uid", name: "USB Mic"))

        selection.choose(nil)

        XCTAssertNil(selection.chosen)
        XCTAssertNil(InputDeviceSelection(storage: storage).chosen)
    }

    func testChangeNotifiesObserver() {
        let selection = InputDeviceSelection(storage: storage)
        var changes = 0
        selection.onChange = { changes += 1 }

        selection.choose(InputDevice(uid: "usb-mic-uid", name: "USB Mic"))
        selection.choose(nil)

        XCTAssertEqual(changes, 2)
    }
}