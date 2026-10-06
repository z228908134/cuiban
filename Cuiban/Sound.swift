import AVFoundation
import Foundation

/// 催促页打开时循环播放警报音（.playback 分类，静音键拨到静音也照响）
final class AlarmSound {
    static let shared = AlarmSound()
    private var player: AVAudioPlayer?

    func start() {
        guard player == nil else { return }
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default, options: [.duckOthers])
        try? session.setActive(true)
        guard let url = Bundle.main.url(forResource: "nag", withExtension: "wav") else { return }
        player = try? AVAudioPlayer(contentsOf: url)
        player?.numberOfLoops = -1
        player?.volume = 1.0
        player?.play()
    }

    func stop() {
        player?.stop()
        player = nil
    }
}

/// 后台常驻：循环播放一段近乎无声的音频，让系统不挂起本 App，
/// 这样催促循环可以一直在后台跑，实现真正「无限催」。
final class BackgroundKeeper {
    static let shared = BackgroundKeeper()
    private var player: AVAudioPlayer?
    private(set) var isRunning = false

    func start() {
        guard !isRunning else { return }
        guard let url = Bundle.main.url(forResource: "silence", withExtension: "wav") else { return }
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        try? session.setActive(true)
        player = try? AVAudioPlayer(contentsOf: url)
        player?.numberOfLoops = -1
        player?.volume = 0.01
        player?.play()
        isRunning = true
    }

    func stop() {
        player?.stop()
        player = nil
        isRunning = false
    }
}
