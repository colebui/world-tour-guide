import Foundation
import Combine
import AVFoundation

/// Speaks guide text aloud using the on-device speech synthesizer (free, offline).
/// Configured for spoken audio so it plays over the silent switch and can continue
/// in the background (with the Audio background mode enabled).
@MainActor
final class SpeechService: NSObject, ObservableObject {
    private let synthesizer = AVSpeechSynthesizer()
    private var audioPlayer: AVAudioPlayer?
    private var playTask: Task<Void, Never>?
    private var audioCache: [String: Data] = [:]   // url string -> mp3 bytes

    @Published var isSpeaking = false
    @Published var isPreparing = false

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    /// Plays the cached neural narration MP3 if available; otherwise falls back to the on-device
    /// synthesizer (offline / audio not generated yet).
    func playGuide(audioURL: String?, fallbackText: String) {
        if isSpeaking || isPreparing { stop(); return }
        if let audioURL, let url = URL(string: audioURL) {
            play(url: url, cacheKey: audioURL, fallbackText: fallbackText)
        } else {
            speak(fallbackText)
        }
    }

    /// Downloads the full MP3 then plays it with AVAudioPlayer — far more reliable than
    /// streaming a remote URL via AVPlayer (which fails in the simulator). Caches the bytes.
    private func play(url: URL, cacheKey: String, fallbackText: String) {
        configureSession()
        stopPlayback()
        isPreparing = true
        playTask = Task { [weak self] in
            guard let self else { return }
            do {
                let data: Data
                if let cached = self.audioCache[cacheKey] {
                    data = cached
                } else {
                    let (downloaded, _) = try await URLSession.shared.data(from: url)
                    try Task.checkCancellation()
                    self.audioCache[cacheKey] = downloaded
                    data = downloaded
                }
                let player = try AVAudioPlayer(data: data)
                player.delegate = self
                self.audioPlayer = player
                self.isPreparing = false
                self.isSpeaking = true
                player.play()
            } catch is CancellationError {
                // stopped before playback started
            } catch {
                print("audio play failed, falling back to on-device voice: \(error)")
                self.isPreparing = false
                self.speak(fallbackText)
            }
        }
    }

    func speak(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        configureSession()
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
        let utterance = AVSpeechUtterance(string: trimmed)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        utterance.voice = AVSpeechSynthesisVoice(language: Locale.preferredLanguages.first ?? "en-US")
        synthesizer.speak(utterance)
    }

    func stop() {
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
        stopPlayback()
        isSpeaking = false
        isPreparing = false
    }

    private func stopPlayback() {
        playTask?.cancel()
        playTask = nil
        audioPlayer?.stop()
        audioPlayer = nil
    }

    /// Play if idle, stop if currently speaking. (On-device voice only — kept for callers.)
    func toggle(_ text: String) {
        if isSpeaking {
            stop()
        } else {
            speak(text)
        }
    }

    private func configureSession() {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            print("audio session error: \(error)")
        }
    }
}

extension SpeechService: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in self.isSpeaking = false }
    }
}

extension SpeechService: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        Task { @MainActor in self.isSpeaking = true }
    }
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.isSpeaking = false }
    }
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in self.isSpeaking = false }
    }
}
