import AppKit
import DictationCore

/// "Microfone" submenu: the system default plus every input device, with the chosen one marked.
/// Rebuilt on refresh because devices come and go; changes are refused during a session.
@MainActor
final class MicrophoneMenu: NSObject, NSMenuDelegate {
    let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")

    private let catalog: InputDeviceCatalog
    private let selection: InputDeviceSelection
    private let isIdle: @MainActor () -> Bool

    init(catalog: InputDeviceCatalog, selection: InputDeviceSelection, isIdle: @escaping @MainActor () -> Bool) {
        self.catalog = catalog
        self.selection = selection
        self.isIdle = isIdle
        super.init()
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        submenu.delegate = self
        item.submenu = submenu
    }

    func menuWillOpen(_ menu: NSMenu) { refresh() }

    func refresh() {
        let devices = catalog.inputDevices()
        let systemName = catalog.defaultInputDevice()?.name ?? "nenhum disponível"
        let chosen = selection.chosen
        let chosenIsConnected = chosen.map { choice in devices.contains { $0.uid == choice.uid } } ?? false
        let idle = isIdle()

        switch (chosen, chosenIsConnected) {
        case (nil, _) where catalog.defaultInputDevice() == nil: item.title = "Microfone: nenhum disponível"
        case (nil, _): item.title = "Microfone: padrão do sistema (\(systemName))"
        case let (choice?, true): item.title = "Microfone: \(choice.name)"
        case let (choice?, false): item.title = "Microfone: \(choice.name) (desconectado)"
        }

        guard let submenu = item.submenu else { return }
        submenu.removeAllItems()
        let systemItem = choiceItem("Padrão do sistema (\(systemName))", device: nil, enabled: idle)
        systemItem.state = chosen == nil ? .on : .off
        submenu.addItem(systemItem)
        if !devices.isEmpty || chosen != nil { submenu.addItem(.separator()) }
        for device in devices {
            let deviceItem = choiceItem(device.name, device: device, enabled: idle)
            deviceItem.state = device.uid == chosen?.uid ? .on : .off
            submenu.addItem(deviceItem)
        }
        if let chosen, !chosenIsConnected {
            let missing = choiceItem("\(chosen.name) (desconectado)", device: chosen, enabled: false)
            missing.state = .on
            submenu.addItem(missing)
        }
    }

    private func choiceItem(_ title: String, device: InputDevice?, enabled: Bool) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(choose(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = device.map { [$0.uid, $0.name] }
        item.isEnabled = enabled
        return item
    }

    @objc private func choose(_ sender: NSMenuItem) {
        // A disabled item can still be reached by a stale click or programmatically; re-check.
        guard sender.isEnabled, isIdle() else { return }
        if let pair = sender.representedObject as? [String], pair.count == 2 {
            selection.choose(InputDevice(uid: pair[0], name: pair[1]))
        } else {
            selection.choose(nil)
        }
        refresh()
    }
}
