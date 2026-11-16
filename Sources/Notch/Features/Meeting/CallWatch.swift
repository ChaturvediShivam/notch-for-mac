import CoreAudio
import Foundation

/// Starts Meeting mode when a call app starts using the microphone and stops it when the call ends.
/// Polls CoreAudio's per-process "is running input" flag (macOS 14+) every 3 s: cheap, no permission.
@MainActor
final class CallWatch {
    static let shared = CallWatch()

    /// Apps (bundle-id prefixes) whose mic use means a call. Browsers cover Meet and web Zoom/Teams.
    static let callApps = ["us.zoom", "com.microsoft.teams", "com.cisco.webex", "com.tinyspeck.slackmacgap",
                           "com.apple.FaceTime", "com.hnc.Discord", "net.whatsapp", "desktop.WhatsApp",
                           "com.skype", "ru.keepcoder.Telegram", "com.google.Chrome", "com.brave.Browser",
                           "company.thebrowser", "com.microsoft.edgemac", "org.mozilla.firefox", "com.apple.WebKit",
                           "com.apple.Safari", "com.operasoftware"]

    private var timer: Timer?
    private var callSince: Date?, lastCall: Date?
    private var startedByUs = false
    /// You pressed Stop during a call: don't restart until that call ends.
    private var snoozed = false

    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { _ in
            MainActor.assumeIsolated { CallWatch.shared.tick() }
        }
    }

    /// Called when you start or stop Meeting mode yourself.
    func userToggled(nowActive: Bool) {
        startedByUs = false
        if !nowActive, callSince != nil { snoozed = true }
    }

    private func tick() {
        guard Store.shared.config.meetingAuto else { return }
        let mt = MeetingService.shared
        let now = Date()
        if let app = Self.callApp() {
            lastCall = now
            if callSince == nil { callSince = now }
            // 5 s of mic use, so a quick voice search in a browser doesn't start it.
            if !mt.active, !snoozed, now.timeIntervalSince(callSince!) >= 5 {
                mt.log("auto start: \(app) is using the microphone")
                startedByUs = true
                Task { await mt.start() }
            }
        } else {
            callSince = nil; snoozed = false
            // 15 s grace: some apps release the mic briefly (mute, switching devices).
            if mt.active, startedByUs, let l = lastCall, now.timeIntervalSince(l) >= 15 {
                mt.log("auto stop: no call app is using the microphone")
                startedByUs = false
                mt.stop()
            }
        }
    }

    /// Bundle id of a call app currently recording from a microphone, if any.
    static func callApp() -> String? {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        let sys = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(sys, &addr, 0, nil, &size) == noErr, size > 0 else { return nil }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(sys, &addr, 0, nil, &size, &ids) == noErr else { return nil }
        for id in ids {
            var a = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyIsRunningInput,
                                               mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var running: UInt32 = 0, rs = UInt32(MemoryLayout<UInt32>.size)
            guard AudioObjectGetPropertyData(id, &a, 0, nil, &rs, &running) == noErr, running != 0 else { continue }
            a.mSelector = kAudioProcessPropertyBundleID
            var ref: Unmanaged<CFString>?, bs = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            guard AudioObjectGetPropertyData(id, &a, 0, nil, &bs, &ref) == noErr,
                  let bid = ref?.takeRetainedValue() as String? else { continue }
            if callApps.contains(where: { bid.hasPrefix($0) }) { return bid }
        }
        return nil
    }
}
