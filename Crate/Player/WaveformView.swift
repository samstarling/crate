import SwiftUI

/// The playing track's colour waveform with its memory cues, which can be clicked or dragged to seek.
struct WaveformView: View {
    let waveform: Waveform?
    /// Memory cue positions in seconds.
    let memoryCues: [Double]
    let duration: Double
    let position: Double
    /// Called while dragging (`finished == false`) and once on release with the time to seek to.
    let onSeek: (_ time: Double, _ finished: Bool) -> Void

    /// Space above the waveform for cue markers.
    private let markerHeight: CGFloat = 6

    var body: some View {
        GeometryReader { geometry in
            Canvas { context, size in
                let waveformTop = markerHeight
                let midY = waveformTop + (size.height - waveformTop) / 2
                let maxHalfHeight = (size.height - waveformTop) / 2
                let playheadX = x(for: position, width: size.width)

                if let waveform {
                    for (index, column) in waveform.columns(Int(size.width)).enumerated() {
                        let halfHeight = max(0.5, column.height * maxHalfHeight)
                        let rect = CGRect(x: CGFloat(index), y: midY - halfHeight, width: 1, height: halfHeight * 2)
                        let color = Color(red: column.red, green: column.green, blue: column.blue)
                        // Dim what's already been played, like a CDJ.
                        context.fill(Path(rect), with: .color(color.opacity(CGFloat(index) < playheadX ? 0.45 : 1)))
                    }
                } else {
                    context.fill(Path(CGRect(x: 0, y: midY - 1, width: size.width, height: 2)), with: .color(.secondary.opacity(0.4)))
                }

                for cue in memoryCues {
                    let cueX = x(for: cue, width: size.width)
                    var marker = Path()
                    marker.move(to: CGPoint(x: cueX - 4, y: 0))
                    marker.addLine(to: CGPoint(x: cueX + 4, y: 0))
                    marker.addLine(to: CGPoint(x: cueX, y: markerHeight))
                    marker.closeSubpath()
                    context.fill(marker, with: .color(.red))
                }

                context.fill(Path(CGRect(x: playheadX - 0.5, y: waveformTop, width: 1, height: size.height - waveformTop)), with: .color(.primary))
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { onSeek(time(for: $0.location.x, width: geometry.size.width), false) }
                    .onEnded { onSeek(time(for: $0.location.x, width: geometry.size.width), true) }
            )
        }
        .help("Click or drag to seek. Red markers are memory cues.")
    }

    private func x(for time: Double, width: CGFloat) -> CGFloat {
        duration > 0 ? CGFloat(time / duration) * width : 0
    }

    private func time(for x: CGFloat, width: CGFloat) -> Double {
        guard width > 0 else { return 0 }
        return Double(min(max(x / width, 0), 1)) * duration
    }
}

#Preview {
    @Previewable @State var position = 120.0
    let track = Track.previews[0]
    WaveformView(
        waveform: .preview(duration: track.duration, bpm: track.bpm),
        memoryCues: track.memoryCues,
        duration: Double(track.duration),
        position: position
    ) { time, _ in
        position = time
    }
    .frame(width: 600, height: 40)
    .padding()
}
