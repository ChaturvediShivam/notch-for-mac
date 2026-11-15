import AppKit
import CoreWLAN
import IOKit.pwr_mgt

/// Thin wrappers over the system switches. Private frameworks are loaded with dlopen
/// so a missing symbol on a future macOS just disables that tile instead of crashing.
enum SystemControls {
    // MARK: Brightness (DisplayServices, built-in display)

    private static let ds = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY)
    private typealias GetB = @convention(c) (UInt32, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetB = @convention(c) (UInt32, Float) -> Int32

    static var brightness: Float? {
        guard let p = dlsym(ds, "DisplayServicesGetBrightness") else { return nil }
        var v: Float = 0
        return unsafeBitCast(p, to: GetB.self)(CGMainDisplayID(), &v) == 0 ? v : nil
    }

    static func setBrightness(_ v: Float) {
        guard let p = dlsym(ds, "DisplayServicesSetBrightness") else { return }
        _ = unsafeBitCast(p, to: SetB.self)(CGMainDisplayID(), min(max(v, 0), 1))
    }

    // MARK: Wi-Fi (CoreWLAN)

    static var wifiOn: Bool { CWWiFiClient.shared().interface()?.powerOn() ?? false }
    static var wifiName: String? { CWWiFiClient.shared().interface()?.ssid() }

    static func setWiFi(_ on: Bool) async {
        await Task.detached { try? CWWiFiClient.shared().interface()?.setPower(on) }.value
    }

    // MARK: Bluetooth (IOBluetooth preference functions)

    private static let bt = dlopen("/System/Library/Frameworks/IOBluetooth.framework/IOBluetooth", RTLD_LAZY)
    private typealias GetBT = @convention(c) () -> Int32
    private typealias SetBT = @convention(c) (Int32) -> Void

    static var bluetoothOn: Bool? {
        guard let p = dlsym(bt, "IOBluetoothPreferenceGetControllerPowerState") else { return nil }
        return unsafeBitCast(p, to: GetBT.self)() != 0
    }

    static func setBluetooth(_ on: Bool) async {
        guard let p = dlsym(bt, "IOBluetoothPreferenceSetControllerPowerState") else { return }
        let f = unsafeBitCast(p, to: SetBT.self)
        await Task.detached { f(on ? 1 : 0) }.value
    }

    // MARK: Dark mode (System Events, asks for Automation once)

    static var darkMode: Bool { UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark" }

    static func setDarkMode(_ on: Bool) async {
        await Shell.osascript("tell application \"System Events\" to tell appearance preferences to set dark mode to \(on)")
    }

    // MARK: Night Shift (CoreBrightness CBBlueLightClient)

    private static let blueLight: NSObject? = {
        _ = dlopen("/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness", RTLD_LAZY)
        return (NSClassFromString("CBBlueLightClient") as? NSObject.Type)?.init()
    }()

    static var nightShift: Bool? {
        guard let c = blueLight else { return nil }
        let sel = NSSelectorFromString("getBlueLightStatus:")
        guard c.responds(to: sel) else { return nil }
        typealias F = @convention(c) (AnyObject, Selector, UnsafeMutableRawPointer) -> Bool
        let buf = UnsafeMutableRawPointer.allocate(byteCount: 64, alignment: 8)
        defer { buf.deallocate() }
        buf.initializeMemory(as: UInt8.self, repeating: 0, count: 64)
        guard unsafeBitCast(c.method(for: sel), to: F.self)(c, sel, buf) else { return nil }
        return buf.load(fromByteOffset: 1, as: Bool.self)      // StatusData.enabled
    }

    static func setNightShift(_ on: Bool) {
        guard let c = blueLight else { return }
        let sel = NSSelectorFromString("setEnabled:")
        guard c.responds(to: sel) else { return }
        typealias F = @convention(c) (AnyObject, Selector, Bool) -> Bool
        _ = unsafeBitCast(c.method(for: sel), to: F.self)(c, sel, on)
    }

    // MARK: Keep awake (IOPMAssertion)

    private static var assertion: IOPMAssertionID = 0

    static var keepAwake: Bool { assertion != 0 }

    static func setKeepAwake(_ on: Bool) {
        if on, assertion == 0 {
            IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                                        IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                        "Notch keep awake" as CFString, &assertion)
        } else if !on, assertion != 0 {
            IOPMAssertionRelease(assertion); assertion = 0
        }
    }

    // MARK: Low Power Mode (pmset needs admin: macOS shows its own password prompt)

    static var lowPower: Bool { ProcessInfo.processInfo.isLowPowerModeEnabled }

    static func setLowPower(_ on: Bool) async {
        await Shell.osascript("do shell script \"pmset -a lowpowermode \(on ? 1 : 0)\" with administrator privileges")
    }

    // MARK: One-shot actions

    static func lockScreen() {
        let h = dlopen("/System/Library/PrivateFrameworks/login.framework/Versions/Current/login", RTLD_LAZY)
        if let p = dlsym(h, "SACLockScreenImmediate") {
            typealias F = @convention(c) () -> Int32
            _ = unsafeBitCast(p, to: F.self)()
        } else {
            Task { await Shell.run("/usr/bin/pmset", ["displaysleepnow"]) }
        }
    }

    static func sleep() { Task { await Shell.run("/usr/bin/pmset", ["sleepnow"]) } }
    static func sleepDisplay() { Task { await Shell.run("/usr/bin/pmset", ["displaysleepnow"]) } }
    static func emptyTrash() { Task { await Shell.osascript("tell application \"Finder\" to empty trash") } }
}
