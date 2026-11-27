import CoreAudio
import CoreFoundation
import DictationCore

/// Input-device catalog backed by read-only CoreAudio HAL queries. Listing does not open the mic.
@MainActor
final class CoreAudioInputDevices: InputDeviceCatalog {
    func inputDevices() -> [InputDevice] {
        allDevices().compactMap { id in
            guard inputChannels(of: id) > 0,
                  let uid = stringProperty(id, selector: kAudioDevicePropertyDeviceUID),
                  let name = stringProperty(id, selector: kAudioObjectPropertyName) else { return nil }
            return InputDevice(uid: uid, name: name)
        }
    }

    func defaultInputDevice() -> InputDevice? {
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id) == noErr,
              id != kAudioObjectUnknown,
              let uid = stringProperty(id, selector: kAudioDevicePropertyDeviceUID),
              let name = stringProperty(id, selector: kAudioObjectPropertyName) else { return nil }
        return InputDevice(uid: uid, name: name)
    }

    func deviceID(forUID uid: String) -> AudioDeviceID? {
        allDevices().first { stringProperty($0, selector: kAudioDevicePropertyDeviceUID) == uid }
    }

    func inputChannels(of id: AudioDeviceID) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr,
              size >= UInt32(MemoryLayout<AudioBufferList>.size) else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { raw.deallocate() }
        let buffers = raw.bindMemory(to: AudioBufferList.self, capacity: 1)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, buffers) == noErr else { return 0 }
        return UnsafeMutableAudioBufferListPointer(buffers).reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    func nominalSampleRate(of id: AudioDeviceID) -> Double? {
        var rate = Float64(0)
        var size = UInt32(MemoryLayout<Float64>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &rate) == noErr, rate > 0 else { return nil }
        return rate
    }

    private func allDevices() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr,
              size >= UInt32(MemoryLayout<AudioDeviceID>.size) else { return [] }
        var devices = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &devices) == noErr else { return [] }
        return devices
    }

    private func stringProperty(_ id: AudioDeviceID, selector: AudioObjectPropertySelector) -> String? {
        let storage = UnsafeMutablePointer<CFString?>.allocate(capacity: 1)
        storage.initialize(to: nil)
        defer {
            storage.deinitialize(count: 1)
            storage.deallocate()
        }
        var size = UInt32(MemoryLayout<CFString?>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, UnsafeMutableRawPointer(storage)) == noErr,
              let value = storage.pointee else { return nil }
        return value as String
    }
}
