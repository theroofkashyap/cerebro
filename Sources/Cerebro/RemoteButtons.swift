import MediaPlayer

/// Receives headphone button presses, which macOS delivers as media commands to the "now playing" app.
final class RemoteButtons {
    var onSinglePress: (() -> Void)?
    var onDoublePress: (() -> Void)?
    var onTriplePress: (() -> Void)?

    func start() {
        let center = MPRemoteCommandCenter.shared()
        // A single press arrives as play, pause or toggle depending on what the headphones think is playing.
        for command in [center.togglePlayPauseCommand, center.playCommand, center.pauseCommand] {
            command.addTarget { [weak self] _ in self?.deliver { $0.onSinglePress } ?? .commandFailed }
        }
        center.nextTrackCommand.addTarget { [weak self] _ in self?.deliver { $0.onDoublePress } ?? .commandFailed }
        center.previousTrackCommand.addTarget { [weak self] _ in self?.deliver { $0.onTriplePress } ?? .commandFailed }
    }

    /// The buttons are only taken over while the head cursor is on; otherwise they keep controlling music.
    func setActive(_ active: Bool) {
        let center = MPRemoteCommandCenter.shared()
        for command in [center.togglePlayPauseCommand, center.playCommand, center.pauseCommand,
                        center.nextTrackCommand, center.previousTrackCommand] {
            command.isEnabled = active
        }
        if active {
            claim()
        } else {
            let info = MPNowPlayingInfoCenter.default()
            info.nowPlayingInfo = nil
            info.playbackState = .stopped
        }
    }

    /// Takes the "now playing" slot back, e.g. after a music app has grabbed it.
    func claim() {
        let info = MPNowPlayingInfoCenter.default()
        info.nowPlayingInfo = [MPMediaItemPropertyTitle: "Cerebro", MPNowPlayingInfoPropertyPlaybackRate: 1.0]
        // macOS routes media commands to whichever app most recently started "playing".
        info.playbackState = .paused
        info.playbackState = .playing
    }

    private func deliver(_ handler: @escaping (RemoteButtons) -> (() -> Void)?) -> MPRemoteCommandHandlerStatus {
        DispatchQueue.main.async { handler(self)?() }
        return .success
    }
}
