import CoreAudio
import AudioToolbox
import Foundation

struct AudioDevice: Identifiable, Hashable {
    let id: AudioDeviceID
    let name: String
    let isOutput: Bool
}

/// Volume, mute and default devices through CoreAudio. Property listeners keep it live
/// and raise the volume HUD in the closed pill.
@MainActor
final class AudioService: ObservableObject {
    static let shared = AudioService()

    @Published private(set) var volume: Float = 0
    @Published private(set) var muted = false
    @Published private(set) var outputs: [AudioDevice] = []
    @Published private(set) var inputs: [AudioDevice] = []
    @Published private(set) var defaultOutput: AudioDeviceID = 0
    @Published private(set) var defaultInput: AudioDeviceID = 0
    @Published private(set) var inputVolume: Float = 0

    private var listenedDevice: AudioDeviceID = 0
    private var ready = false

    private init() {
        refreshDevices()
        let sys = AudioObjectID(kAudioObjectSystemObject)
        for sel in [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultOutputDevice, kAudioHardwarePropertyDefaultInputDevice] {
            var a = Self.addr(sel)
            AudioObjectAddPropertyListenerBlock(sys, &a, .main) { _, _ in
                MainActor.assumeIsolated { AudioService.shared.refreshDevices() }
            }
        }
        ready = true
    }

    // MARK: Helpers

    private static func addr(_ sel: AudioObjectPropertySelector,
                             _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                             _ element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: sel, mScope: scope, mElement: element)
    }

    private static func get<T: BitwiseCopyable>(_ obj: AudioObjectID, _ a: AudioObjectPropertyAddress, _ initial: T) -> T? {
        var a = a, v = initial, size = UInt32(MemoryLayout<T>.size)
        return AudioObjectGetPropertyData(obj, &a, 0, nil, &size, &v) == noErr ? v : nil
    }

    private static func set<T: BitwiseCopyable>(_ obj: AudioObjectID, _ a: AudioObjectPropertyAddress, _ value: T) {
        var a = a, v = value
        AudioObjectSetPropertyData(obj, &a, 0, nil, UInt32(MemoryLayout<T>.size), &v)
    }

    private static func name(_ id: AudioDeviceID) -> String {
        var a = addr(kAudioObjectPropertyName), size = UInt32(MemoryLayout<CFString?>.size)
        var s: Unmanaged<CFString>?
        guard AudioObjectGetPropertyData(id, &a, 0, nil, &size, &s) == noErr, let s else { return "Device \(id)" }
        return s.takeRetainedValue() as String
    }

    private static func hasStreams(_ id: AudioDeviceID, _ scope: AudioObjectPropertyScope) -> Bool {
        var a = addr(kAudioDevicePropertyStreams, scope), size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(id, &a, 0, nil, &size) == noErr && size > 0
    }

    // MARK: Devices

    private static func transport(_ id: AudioDeviceID) -> UInt32 {
        get(id, addr(kAudioDevicePropertyTransportType), UInt32(0)) ?? 0
    }

    /// Like macOS does for AirPods: a headphone/USB/Bluetooth output that gets plugged in
    /// becomes the output (USB earphones and dongles otherwise stay on the speakers).
    private func switchToNewOutput(_ old: [AudioDevice]) {
        guard ready, Store.shared.config.autoSwitchOutput else { return }
        let real: Set<UInt32> = [kAudioDeviceTransportTypeUSB, kAudioDeviceTransportTypeBluetooth,
                                 kAudioDeviceTransportTypeBluetoothLE, kAudioDeviceTransportTypeHDMI,
                                 kAudioDeviceTransportTypeDisplayPort, kAudioDeviceTransportTypeThunderbolt]
        let oldIDs = Set(old.map(\.id))
        guard let new = outputs.first(where: { !oldIDs.contains($0.id) && real.contains(Self.transport($0.id)) }),
              new.id != defaultOutput else { return }
        let sys = AudioObjectID(kAudioObjectSystemObject)
        Self.set(sys, Self.addr(kAudioHardwarePropertyDefaultOutputDevice), new.id)
        Self.set(sys, Self.addr(kAudioHardwarePropertyDefaultSystemOutputDevice), new.id)
        defaultOutput = new.id
        AlertsService.shared.add(title: "Sound → \(new.name)", body: "Switched output to the device you just connected.", source: "Audio")
    }

    func refreshDevices() {
        let previousOutputs = outputs
        defer { switchToNewOutput(previousOutputs) }
        let sys = AudioObjectID(kAudioObjectSystemObject)
        var a = Self.addr(kAudioHardwarePropertyDevices), size: UInt32 = 0
        AudioObjectGetPropertyDataSize(sys, &a, 0, nil, &size)
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        AudioObjectGetPropertyData(sys, &a, 0, nil, &size, &ids)
        outputs = ids.filter { Self.hasStreams($0, kAudioDevicePropertyScopeOutput) }
            .map { AudioDevice(id: $0, name: Self.name($0), isOutput: true) }
        inputs = ids.filter { Self.hasStreams($0, kAudioDevicePropertyScopeInput) }
            .map { AudioDevice(id: $0, name: Self.name($0), isOutput: false) }
        defaultOutput = Self.get(sys, Self.addr(kAudioHardwarePropertyDefaultOutputDevice), AudioDeviceID(0)) ?? 0
        defaultInput = Self.get(sys, Self.addr(kAudioHardwarePropertyDefaultInputDevice), AudioDeviceID(0)) ?? 0
        listenToOutput()
        readVolume(hud: false)
        inputVolume = Self.get(defaultInput, Self.addr(kAudioDevicePropertyVolumeScalar, kAudioDevicePropertyScopeInput), Float32(0)) ?? 0
    }

    func setDefault(_ d: AudioDevice) {
        let sel = d.isOutput ? kAudioHardwarePropertyDefaultOutputDevice : kAudioHardwarePropertyDefaultInputDevice
        Self.set(AudioObjectID(kAudioObjectSystemObject), Self.addr(sel), d.id)
        refreshDevices()
    }

    private func listenToOutput() {
        guard defaultOutput != listenedDevice, defaultOutput != 0 else { return }
        listenedDevice = defaultOutput
        let dev = defaultOutput
        for sel in [kAudioHardwareServiceDeviceProperty_VirtualMainVolume, kAudioDevicePropertyMute] {
            var a = Self.addr(sel, kAudioDevicePropertyScopeOutput)
            AudioObjectAddPropertyListenerBlock(dev, &a, .main) { _, _ in
                MainActor.assumeIsolated {
                    guard AudioService.shared.defaultOutput == dev else { return }
                    AudioService.shared.readVolume(hud: true)
                }
            }
        }
    }

    // MARK: Volume

    private func readVolume(hud: Bool) {
        let v = Self.get(defaultOutput, Self.addr(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, kAudioDevicePropertyScopeOutput), Float32(0)) ?? 0
        let m = (Self.get(defaultOutput, Self.addr(kAudioDevicePropertyMute, kAudioDevicePropertyScopeOutput), UInt32(0)) ?? 0) != 0
        let changed = abs(v - volume) > 0.001 || m != muted
        volume = v; muted = m
        if hud, changed, ready, !(NotchModel.shared?.isOpen ?? true) {
            NotchModel.shared?.showHUD(volumeSymbol, Double(m ? 0 : v))
        }
    }

    var volumeSymbol: String {
        if muted || volume == 0 { return "speaker.slash.fill" }
        return volume < 0.33 ? "speaker.wave.1.fill" : volume < 0.66 ? "speaker.wave.2.fill" : "speaker.wave.3.fill"
    }

    func setVolume(_ v: Float) {
        let v = min(max(v, 0), 1)
        Self.set(defaultOutput, Self.addr(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, kAudioDevicePropertyScopeOutput), Float32(v))
        if muted, v > 0 { setMuted(false) }
        volume = v
    }

    func setMuted(_ m: Bool) {
        Self.set(defaultOutput, Self.addr(kAudioDevicePropertyMute, kAudioDevicePropertyScopeOutput), UInt32(m ? 1 : 0))
        muted = m
    }

    func setInputVolume(_ v: Float) {
        Self.set(defaultInput, Self.addr(kAudioDevicePropertyVolumeScalar, kAudioDevicePropertyScopeInput), Float32(v))
        inputVolume = v
    }
}
