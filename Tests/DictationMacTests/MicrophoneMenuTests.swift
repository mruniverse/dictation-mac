import AppKit
import DictationCore
@testable import DictationMac
import XCTest

@MainActor
private final class FakeInputDevices: InputDeviceCatalog {
    var devices: [InputDevice] = []
    var systemDefault: InputDevice?

    func inputDevices() -> [InputDevice] { devices }
    func defaultInputDevice() -> InputDevice? { systemDefault }
}

@MainActor
final class MicrophoneMenuTests: XCTestCase {
    private let lineIn = InputDevice(uid: "line-in", name: "Entrada de Linha Integrada")
    private let webcam = InputDevice(uid: "usb-webcam", name: "GENERAL WEBCAM")
    private var suite: String!
    private var storage: UserDefaults!
    private var catalog: FakeInputDevices!
    private var idle = true

    override func setUp() async throws {
        _ = NSApplication.shared
        suite = "MicrophoneMenuTests-\(UUID().uuidString)"
        storage = try XCTUnwrap(UserDefaults(suiteName: suite))
        catalog = FakeInputDevices()
        catalog.devices = [lineIn, webcam]
        catalog.systemDefault = lineIn
        idle = true
    }

    override func tearDown() async throws {
        storage.removePersistentDomain(forName: suite)
    }

    private func makeMenu() -> (MicrophoneMenu, InputDeviceSelection) {
        let selection = InputDeviceSelection(storage: storage)
        let menu = MicrophoneMenu(catalog: catalog, selection: selection, isIdle: { [unowned self] in idle })
        menu.refresh()
        return (menu, selection)
    }

    private func items(_ menu: MicrophoneMenu) -> [NSMenuItem] {
        menu.item.submenu?.items.filter { !$0.isSeparatorItem } ?? []
    }

    func testListsTheSystemDefaultAndEveryInputDevice() {
        let (menu, _) = makeMenu()

        XCTAssertEqual(menu.item.title, "Microfone: padrão do sistema (Entrada de Linha Integrada)")
        XCTAssertEqual(items(menu).map(\.title), [
            "Padrão do sistema (Entrada de Linha Integrada)", "Entrada de Linha Integrada", "GENERAL WEBCAM",
        ])
        XCTAssertEqual(items(menu).map(\.state), [.on, .off, .off])
    }

    func testChoosingADeviceMarksItAndPersistsIt() throws {
        let (menu, selection) = makeMenu()
        let item = try XCTUnwrap(items(menu).first { $0.title == "GENERAL WEBCAM" })

        menu.item.submenu?.performActionForItem(at: try XCTUnwrap(menu.item.submenu?.index(of: item)))

        XCTAssertEqual(selection.chosen, webcam)
        XCTAssertEqual(menu.item.title, "Microfone: GENERAL WEBCAM")
        XCTAssertEqual(items(menu).map(\.state), [.off, .off, .on])
    }

    func testChoosingTheSystemDefaultForgetsTheDevice() throws {
        let (menu, selection) = makeMenu()
        selection.choose(webcam)
        menu.refresh()

        menu.item.submenu?.performActionForItem(at: 0)

        XCTAssertNil(selection.chosen)
        XCTAssertEqual(items(menu).map(\.state), [.on, .off, .off])
    }

    func testDisconnectedChoiceStaysVisibleAndChosen() {
        let (menu, selection) = makeMenu()
        selection.choose(webcam)
        catalog.devices = [lineIn]

        menu.refresh()

        XCTAssertEqual(menu.item.title, "Microfone: GENERAL WEBCAM (desconectado)")
        XCTAssertEqual(items(menu).map(\.title), [
            "Padrão do sistema (Entrada de Linha Integrada)", "Entrada de Linha Integrada", "GENERAL WEBCAM (desconectado)",
        ])
        XCTAssertEqual(items(menu).map(\.state), [.off, .off, .on])
        XCTAssertFalse(items(menu)[2].isEnabled)
    }

    func testDeviceCannotChangeDuringASession() throws {
        let (menu, selection) = makeMenu()
        idle = false
        menu.refresh()

        XCTAssertTrue(items(menu).allSatisfy { !$0.isEnabled })
        let webcamIndex = try XCTUnwrap(menu.item.submenu?.indexOfItem(withTitle: "GENERAL WEBCAM"))
        menu.item.submenu?.performActionForItem(at: webcamIndex)
        XCTAssertNil(selection.chosen, "A disabled item reached by a stale click must not switch the device")
    }

    func testWithoutAnyInputDeviceSaysSo() {
        catalog.devices = []
        catalog.systemDefault = nil
        let (menu, _) = makeMenu()

        XCTAssertEqual(menu.item.title, "Microfone: nenhum disponível")
        XCTAssertEqual(items(menu).map(\.title), ["Padrão do sistema (nenhum disponível)"])
    }

    func testOpeningSubmenuRefreshesDevicesThatWereConnectedOrRemoved() throws {
        let (menu, _) = makeMenu()
        catalog.devices = [webcam]

        menu.menuWillOpen(try XCTUnwrap(menu.item.submenu))

        XCTAssertEqual(items(menu).map(\.title), ["Padrão do sistema (Entrada de Linha Integrada)", "GENERAL WEBCAM"])
    }
}