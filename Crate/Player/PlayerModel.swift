import AVFoundation
import Observation

@Observable
final class PlayerModel {
    private(set) var track: Track?
    private(set) var isPlaying = false
    /// Playback position in seconds.
    private(set) var currentTime: Double = 0
    /// The playing track's waveform, once loaded; `nil` while loading or if it hasn't been analysed.
    private(set) var waveform: Waveform?
    var errorMessage: String?

    @ObservationIgnored private let player = AVPlayer()
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var endObserver: NSObjectProtocol?

    init() {
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                self?.currentTime = time.seconds
            }
        }
        endObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.isPlaying = false
                self?.seek(to: 0)
            }
        }
    }

    /// The track's length, preferring the real file's duration over Rekordbox's rounded value.
    var duration: Double {
        let seconds = player.currentItem?.duration.seconds ?? .nan
        return seconds.isFinite ? seconds : Double(track?.duration ?? 0)
    }

    func play(_ track: Track) {
        guard FileManager.default.fileExists(atPath: track.fileURL.path) else {
            errorMessage = "\u{201C}\(track.title)\u{201D} couldn't be found at \(track.fileURL.path)."
            return
        }
        self.track = track
        currentTime = 0
        waveform = nil
        if let analysisURL = track.analysisURL {
            Task {
                let waveform = await Task.detached(priority: .userInitiated) { try? Waveform.load(from: analysisURL) }.value
                if self.track?.id == track.id {
                    self.waveform = waveform
                }
            }
        }
        player.replaceCurrentItem(with: AVPlayerItem(url: track.fileURL))
        player.play()
        isPlaying = true
    }

    func togglePlayPause() {
        guard track != nil else { return }
        if isPlaying {
            player.pause()
        } else {
            player.play()
        }
        isPlaying.toggle()
    }

    func seek(to seconds: Double) {
        currentTime = seconds
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }
}

extension PlayerModel {
    /// A player showing `track` as loaded and paused at `time`, without opening its audio file.
    static func preview(_ track: Track, waveform: Waveform?, at time: Double) -> PlayerModel {
        let player = PlayerModel()
        player.track = track
        player.waveform = waveform
        player.currentTime = time
        return player
    }
}
