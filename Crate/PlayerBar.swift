import SwiftUI

/// Now-playing controls shown along the bottom of the window.
struct PlayerBar: View {
    @Environment(PlayerModel.self) private var player
    /// The position being dragged to, so periodic time updates don't fight the slider.
    @State private var scrubPosition: Double?

    var body: some View {
        if let track = player.track {
            HStack(spacing: 12) {
                Button {
                    player.togglePlayPause()
                } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title2)
                        .frame(width: 24)
                }
                .buttonStyle(.borderless)
                .help(player.isPlaying ? "Pause" : "Play")

                artwork(for: track)

                VStack(alignment: .leading, spacing: 2) {
                    Text(track.title).fontWeight(.medium)
                    Text(track.artist).foregroundStyle(.secondary)
                }
                .lineLimit(1)
                .frame(width: 220, alignment: .leading)

                Text(format(scrubPosition ?? player.currentTime))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                WaveformView(
                    waveform: player.waveform,
                    memoryCues: track.memoryCues,
                    duration: player.duration,
                    position: scrubPosition ?? player.currentTime
                ) { time, finished in
                    if finished {
                        player.seek(to: time)
                        scrubPosition = nil
                    } else {
                        scrubPosition = time
                    }
                }
                .frame(height: 40)
                Text("-" + format(max(0, player.duration - (scrubPosition ?? player.currentTime))))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(.bar)
            .overlay(alignment: .top) { Divider() }
        }
    }

    private func artwork(for track: Track) -> some View {
        Group {
            if let url = track.artworkURL, let image = NSImage(contentsOf: url) {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                Rectangle().fill(.quaternary)
            }
        }
        .frame(width: 36, height: 36)
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    private func format(_ seconds: Double) -> String {
        Duration.seconds(Int(seconds.isFinite ? seconds : 0)).formatted(.time(pattern: .minuteSecond))
    }
}

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
