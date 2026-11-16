import SwiftUI

struct AudioView: View {
    @ObservedObject private var audio = AudioService.shared

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Card(title: "Output") {
                VStack(spacing: 8) {
                    SliderRow(symbol: audio.volumeSymbol,
                              value: Binding(get: { Double(audio.muted ? 0 : audio.volume) }, set: { audio.setVolume(Float($0)) })) {
                        audio.setMuted(!audio.muted)
                    }
                    deviceList(audio.outputs, selected: audio.defaultOutput)
                }
            }
            Card(title: "Input") {
                VStack(spacing: 8) {
                    SliderRow(symbol: "mic.fill",
                              value: Binding(get: { Double(audio.inputVolume) }, set: { audio.setInputVolume(Float($0)) }))
                    deviceList(audio.inputs, selected: audio.defaultInput)
                }
            }
        }
        .onAppear { audio.refreshDevices() }
    }

    private func deviceList(_ list: [AudioDevice], selected: UInt32) -> some View {
        ScrollView {
            VStack(spacing: 2) {
                ForEach(list) { d in
                    Button { audio.setDefault(d) } label: {
                        HStack {
                            Image(systemName: d.isOutput ? "hifispeaker.fill" : "mic").frame(width: 18)
                            Text(d.name).font(Theme.caption).lineLimit(1)
                            Spacer()
                            if d.id == selected { Image(systemName: "checkmark").foregroundStyle(Theme.accent) }
                        }
                        .padding(.horizontal, 8).frame(height: 28)
                        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(d.id == selected ? Theme.control : .clear))
                    }
                    .buttonStyle(GlyphButtonStyle(radius: 8))
                }
            }
        }
    }
}
