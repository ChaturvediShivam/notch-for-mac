import AVFoundation
import Vision
import os

/// Delivery coach: while you practise, the camera (on this Mac, never saved) tracks where your eyes
/// are and whether they sweep across lines like reading; MeetingService adds how you paced the answer.
/// ponytail: Vision pupil landmarks are rough; good for "you read 9 lines", not for exact gaze.
final class GazeTracker: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    static let shared = GazeTracker()

    /// One camera frame: face seen? head turned away? pupil position inside the eye (0…1, x across, y up).
    struct Frame { let t: Date; let face: Bool; let away: Bool; let h: Float; let v: Float }

    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "notch.gaze", qos: .utility)
    private let frames = OSAllocatedUnfairLock(initialState: [Frame]())
    private var lastFrame = Date.distantPast
    private(set) var running = false

    func start() {
        guard !running else { return }
        running = true
        AVCaptureDevice.requestAccess(for: .video) { [self] ok in
            guard ok else { running = false; return }
            queue.async { [self] in
                if session.inputs.isEmpty {
                    session.sessionPreset = .vga640x480
                    guard let dev = AVCaptureDevice.default(for: .video), let input = try? AVCaptureDeviceInput(device: dev),
                          session.canAddInput(input) else { running = false; return }
                    session.addInput(input)
                    let out = AVCaptureVideoDataOutput()
                    out.alwaysDiscardsLateVideoFrames = true
                    out.setSampleBufferDelegate(self, queue: queue)
                    if session.canAddOutput(out) { session.addOutput(out) }
                }
                frames.withLock { $0.removeAll() }
                session.startRunning()
            }
        }
    }

    func stop() {
        running = false
        queue.async { [self] in session.stopRunning(); frames.withLock { $0.removeAll() } }
    }

    func frames(from: Date, to: Date) -> [Frame] { frames.withLock { $0.filter { $0.t >= from && $0.t <= to } } }
    func allFrames() -> [Frame] { frames.withLock { $0 } }

    func captureOutput(_ output: AVCaptureOutput, didOutput sb: CMSampleBuffer, from connection: AVCaptureConnection) {
        let now = Date()
        guard now.timeIntervalSince(lastFrame) >= 1.0 / 12, let px = CMSampleBufferGetImageBuffer(sb) else { return }   // 12 fps is plenty
        lastFrame = now
        let req = VNDetectFaceLandmarksRequest()
        try? VNImageRequestHandler(cvPixelBuffer: px, orientation: .up).perform([req])
        var f = Frame(t: now, face: false, away: true, h: 0, v: 0)
        if let face = req.results?.first, let lm = face.landmarks,
           let lp = lm.leftPupil?.normalizedPoints.first, let rp = lm.rightPupil?.normalizedPoints.first,
           let le = lm.leftEye?.normalizedPoints, let re = lm.rightEye?.normalizedPoints {
            func ratio(_ p: CGPoint, _ eye: [CGPoint]) -> (Float, Float) {
                let xs = eye.map(\.x), ys = eye.map(\.y)
                let w = max((xs.max() ?? 1) - (xs.min() ?? 0), 0.001), h = max((ys.max() ?? 1) - (ys.min() ?? 0), 0.001)
                return (Float((p.x - (xs.min() ?? 0)) / w), Float((p.y - (ys.min() ?? 0)) / h))
            }
            let (lh, lv) = ratio(lp, le), (rh, rv) = ratio(rp, re)
            let yaw = abs(face.yaw?.floatValue ?? 0)
            f = Frame(t: now, face: true, away: yaw > 0.45, h: (lh + rh) / 2, v: (lv + rv) / 2)
        }
        let frame = f
        frames.withLock {
            $0.append(frame)
            if $0.count > 12 * 60 * 30 { $0.removeFirst($0.count - 12 * 60 * 30) }   // last 30 min
        }
    }

    /// Where the eyes were, and how many reading return-sweeps (slow drift across, then a quick jump back).
    struct Gaze { var seconds = 0.0, up = 0.0, level = 0.0, down = 0.0, away = 0.0, sweeps = 0 }

    static func summarize(_ fs: [Frame], baseline: [Frame]) -> Gaze? {
        guard fs.count >= 12 else { return nil }   // under ~1 s of camera: nothing to say
        // "Up" and "down" are relative to how this person usually holds their eyes.
        let vs = baseline.filter { $0.face && !$0.away }.map(\.v).sorted()
        let mid = vs.isEmpty ? 0.5 : vs[vs.count / 2]
        var g = Gaze(seconds: fs.last!.t.timeIntervalSince(fs.first!.t))
        for f in fs {
            if !f.face || f.away { g.away += 1 }
            else if f.v > mid + 0.1 { g.up += 1 }
            else if f.v < mid - 0.1 { g.down += 1 }
            else { g.level += 1 }
        }
        let n = Double(fs.count)
        g.up /= n; g.level /= n; g.down /= n; g.away /= n
        // Reading: eyes drift one way along a line (≥ 0.12 over ≥ 3 frames), then jump back (≥ 0.1 in 1–2 frames).
        let hs = fs.filter { $0.face && !$0.away }.map(\.h)
        var i = 2, drift: Float = 0, steps = 0
        while i < hs.count {
            let d = hs[i] - hs[i - 1]
            if abs(d) < 0.08 { drift += d; steps += 1 }
            else if steps >= 3, abs(drift) >= 0.12, (d > 0) != (drift > 0), abs(hs[i] - hs[i - 2]) >= 0.1 { g.sweeps += 1; drift = 0; steps = 0 }
            else { drift = 0; steps = 0 }
            i += 1
        }
        return g
    }
}
