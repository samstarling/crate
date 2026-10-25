import AVFoundation
import Observation

@Observable
final class PlayerModel {
    private(set) var track: Track?
    private(set) var isPlaying = false
    /// Playback position in seconds.
    private(set) var currentTime: Double = 0
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
