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
