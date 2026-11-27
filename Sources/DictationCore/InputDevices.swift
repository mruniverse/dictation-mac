import Foundation

/// An audio input device, identified by its stable CoreAudio UID.
public struct InputDevice: Equatable, Sendable {
    public let uid: String
    public let name: String

    public init(uid: String, name: String) {
        self.uid = uid
        self.name = name
    }
}

@MainActor
public protocol InputDeviceCatalog {
    /// Devices with at least one input channel, in system order.
    func inputDevices() -> [InputDevice]
    func defaultInputDevice() -> InputDevice?
}

/// The input device capture uses: none chosen means the system default. Stored as the device's
/// UID, plus its last known name so a disconnected choice can still be shown.
@MainActor
public final class InputDeviceSelection {
    private static let uidKey = "audioInput.deviceUID"
    private static let nameKey = "audioInput.deviceName"

    public var onChange: (() -> Void)?
    private let storage: UserDefaults

    public init(storage: UserDefaults) {
        self.storage = storage
    }

    public var chosen: InputDevice? {
        guard let uid = storage.string(forKey: Self.uidKey), !uid.isEmpty else { return nil }
        return InputDevice(uid: uid, name: storage.string(forKey: Self.nameKey) ?? uid)
    }

    public func choose(_ device: InputDevice?) {
        if let device {
            storage.set(device.uid, forKey: Self.uidKey)
            storage.set(device.name, forKey: Self.nameKey)
        } else {
            storage.removeObject(forKey: Self.uidKey)
            storage.removeObject(forKey: Self.nameKey)
        }
        onChange?()
    }
}