import AVFoundation
import SwiftUI

/// Camera preview, like a pocket mirror. The camera only runs while this tab is on screen.
struct MirrorView: View {
    @State private var status = AVCaptureDevice.authorizationStatus(for: .video)

    var body: some View {
        Group {
            switch status {
            case .authorized:
                CameraPreview().clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            case .notDetermined:
                VStack(spacing: 10) {
                    Image(systemName: "camera.fill").font(.system(size: 26))
                    Text("Mirror uses your camera to show a live preview here.\nNothing is recorded or saved.")
                        .font(Theme.caption).multilineTextAlignment(.center).foregroundStyle(.white.opacity(0.6))
                    Button("Turn on camera") {
                        AVCaptureDevice.requestAccess(for: .video) { _ in
                            DispatchQueue.main.async { status = AVCaptureDevice.authorizationStatus(for: .video) }
                        }
                    }
                    .buttonStyle(PillButtonStyle(tint: Theme.accent))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            default:
                Hint("Camera access is off. Allow Notch in System Settings → Privacy & Security → Camera.")
            }
        }
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.card))
    }
}

private struct CameraPreview: NSViewRepresentable {
    final class PreviewView: NSView {
        let session = AVCaptureSession()
        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            let layer = AVCaptureVideoPreviewLayer(session: session)
            layer.videoGravity = .resizeAspectFill
            layer.setAffineTransform(CGAffineTransform(scaleX: -1, y: 1))     // mirror
            self.layer = layer
            let s = session
            DispatchQueue.global(qos: .userInitiated).async {
                s.sessionPreset = .high
                if let dev = AVCaptureDevice.default(for: .video), let input = try? AVCaptureDeviceInput(device: dev),
                   s.canAddInput(input) { s.addInput(input) }
                s.startRunning()
            }
        }
        required init?(coder: NSCoder) { nil }
        func stop() { let s = session; DispatchQueue.global().async { s.stopRunning() } }
    }

    func makeNSView(context: Context) -> PreviewView { PreviewView(frame: .zero) }
    func updateNSView(_ v: PreviewView, context: Context) {}
    static func dismantleNSView(_ v: PreviewView, coordinator: ()) { v.stop() }
}
