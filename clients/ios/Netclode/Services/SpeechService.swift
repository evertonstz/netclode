@preconcurrency import AVFoundation
import Foundation
import os.log
import Speech

private let logger = Logger(subsystem: "com.netclode", category: "SpeechService")

/// Provides speech-to-text transcription using Apple's SpeechAnalyzer API (iOS 26+).
/// Streams live audio from the microphone and returns transcribed text.
@MainActor
@Observable
final class SpeechService {

    // MARK: - Types

    enum State: Equatable, Sendable {
        case idle
        case preparingModel
        case recording
        case processing
        case error(String)

        var isRecording: Bool {
            self == .recording
        }
    }

    enum SpeechError: LocalizedError {
        case notAuthorized
        case modelNotSupported
        case modelDownloadFailed
        case audioSessionFailed(Error)
        case transcriptionFailed(Error)

        var errorDescription: String? {
            switch self {
            case .notAuthorized:
                return "Microphone or speech recognition access denied"
            case .modelNotSupported:
                return "Speech recognition not supported for this language"
            case .modelDownloadFailed:
                return "Failed to download speech recognition model"
            case .audioSessionFailed(let error):
                return "Audio session error: \(error.localizedDescription)"
            case .transcriptionFailed(let error):
                return "Transcription error: \(error.localizedDescription)"
            }
        }
    }

    // MARK: - Properties

    private(set) var state: State = .idle
    private(set) var volatileTranscript: String = ""
    private(set) var finalizedTranscript: String = ""
    private(set) var audioLevel: Float = 0.0

    /// Combined transcript (finalized + volatile)
    var currentTranscript: String {
        let combined = finalizedTranscript + volatileTranscript
        return combined.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var transcriber: SpeechTranscriber?
    private var analyzer: SpeechAnalyzer?
    private var analyzerFormat: AVAudioFormat?
    private var inputBuilder: AsyncStream<AnalyzerInput>.Continuation?
    private var inputSequence: AsyncStream<AnalyzerInput>?

    private var audioEngine: AVAudioEngine?
    private var recognizerTask: Task<Void, Never>?

    private let locale: Locale

    // MARK: - Initialization

    init(locale: Locale = .current) {
        self.locale = locale
    }

    // MARK: - Public Methods

    /// Check if speech recognition is available
    static func isAvailable() async -> Bool {
        let supported = await SpeechTranscriber.supportedLocales
        return supported.contains { $0.identifier(.bcp47) == Locale.current.identifier(.bcp47) }
    }

    /// Request necessary permissions for speech recognition
    func requestPermissions() async -> Bool {
        // Request microphone permission (use nonisolated helper to avoid executor issues)
        let micStatus = await Self.requestMicrophonePermission()

        guard micStatus else {
            logger.warning("Microphone permission denied")
            return false
        }

        // Request speech recognition permission
        let speechStatus = await Self.requestSpeechPermission()

        guard speechStatus else {
            logger.warning("Speech recognition permission denied")
            return false
        }

        return true
    }
    
    /// Request microphone permission (nonisolated to avoid executor issues)
    private nonisolated static func requestMicrophonePermission() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }
    
    /// Request speech recognition permission (nonisolated to avoid executor issues)
    private nonisolated static func requestSpeechPermission() async -> Bool {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }

    /// Start recording and transcribing speech
    func startRecording() async throws {
        guard state == .idle else {
            logger.warning("Cannot start recording: state is \(String(describing: self.state))")
            return
        }

        // Clear previous transcripts
        volatileTranscript = ""
        finalizedTranscript = ""

        // Check permissions
        guard await requestPermissions() else {
            state = .error("Permissions denied")
            throw SpeechError.notAuthorized
        }

        state = .preparingModel

        do {
            // Set up transcriber
            try await setupTranscriber()

            // Set up audio session
            try setupAudioSession()

            // Start audio engine
            try await startAudioEngine()

            state = .recording
            logger.info("Started recording")

        } catch {
            state = .error(error.localizedDescription)
            throw error
        }
    }

    /// Stop recording and finalize transcription
    func stopRecording() async {
        guard state == .recording else { return }

        state = .processing
        logger.info("Stopping recording")

        // Stop audio engine
        audioEngine?.stop()
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine = nil

        // Finalize the stream
        inputBuilder?.finish()

        do {
            try await analyzer?.finalizeAndFinishThroughEndOfInput()
        } catch {
            logger.error("Error finalizing: \(error.localizedDescription)")
        }

        // Wait a moment for final results
        try? await Task.sleep(for: .milliseconds(200))

        // Cancel the recognizer task
        recognizerTask?.cancel()
        recognizerTask = nil

        // Clean up
        transcriber = nil
        analyzer = nil
        inputBuilder = nil
        inputSequence = nil

        state = .idle
        logger.info("Recording stopped. Final transcript: \(self.currentTranscript.prefix(100))...")
    }

    /// Cancel recording without finalizing
    func cancelRecording() async {
        logger.info("Cancelling recording")

        audioEngine?.stop()
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine = nil

        inputBuilder?.finish()
        recognizerTask?.cancel()
        recognizerTask = nil

        await analyzer?.cancelAndFinishNow()

        transcriber = nil
        analyzer = nil
        inputBuilder = nil
        inputSequence = nil

        volatileTranscript = ""
        finalizedTranscript = ""
        state = .idle
    }

    // MARK: - Private Methods

    private func setupTranscriber() async throws {
        // Create transcriber with volatile results for real-time feedback
        transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults],
            attributeOptions: []
        )

        guard let transcriber else {
            throw SpeechError.transcriptionFailed(
                NSError(domain: "SpeechService", code: -1, userInfo: [
                    NSLocalizedDescriptionKey: "Failed to create transcriber"
                ])
            )
        }

        // Create analyzer
        analyzer = SpeechAnalyzer(modules: [transcriber])

        // Get audio format
        analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])

        // Ensure model is available
        try await ensureModel(transcriber: transcriber)

        // Create input stream
        let (sequence, builder) = AsyncStream<AnalyzerInput>.makeStream()
        inputSequence = sequence
        inputBuilder = builder

        // Start analyzer
        try await analyzer?.start(inputSequence: sequence)

        // Start handling results
        startResultsHandler(transcriber: transcriber)
    }

    private func ensureModel(transcriber: SpeechTranscriber) async throws {
        // Check if language is supported
        let supported = await SpeechTranscriber.supportedLocales
        guard supported.contains(where: { $0.identifier(.bcp47) == locale.identifier(.bcp47) }) else {
            logger.error("Locale not supported: \(self.locale.identifier)")
            throw SpeechError.modelNotSupported
        }

        // Check if already installed
        let installed = await SpeechTranscriber.installedLocales
        if installed.contains(where: { $0.identifier(.bcp47) == locale.identifier(.bcp47) }) {
            logger.info("Model already installed for \(self.locale.identifier)")
            return
        }

        // Download model
        logger.info("Downloading speech model for \(self.locale.identifier)")

        if let downloader = try await AssetInventory.assetInstallationRequest(supporting: [transcriber])
        {
            try await downloader.downloadAndInstall()
            logger.info("Model download complete")
        }
    }

    private func setupAudioSession() throws {
        #if os(iOS)
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.playAndRecord, mode: .spokenAudio, options: [.defaultToSpeaker])
            try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
        #endif
    }

    private func startAudioEngine() async throws {
        // Capture values needed before passing to nonisolated helper
        guard let inputBuilder = self.inputBuilder else {
            throw SpeechError.transcriptionFailed(
                NSError(domain: "SpeechService", code: -1, userInfo: [
                    NSLocalizedDescriptionKey: "Input builder not initialized"
                ])
            )
        }
        let targetFormat = self.analyzerFormat
        
        // Start engine using nonisolated helper to avoid MainActor isolation in tap callback
        let (engine, levelStream) = try AudioEngineHelper.startEngine(
            inputBuilder: inputBuilder,
            targetFormat: targetFormat
        )
        audioEngine = engine
        
        // Monitor audio levels
        Task {
            for await level in levelStream {
                self.audioLevel = level
            }
        }
    }

    private func startResultsHandler(transcriber: SpeechTranscriber) {
        recognizerTask = Task { [weak self] in
            do {
                for try await result in transcriber.results {
                    guard let self, !Task.isCancelled else { break }

                    // Convert AttributedString to plain String (avoid .description which includes metadata)
                    let text = String(result.text.characters)

                    if result.isFinal {
                        self.finalizedTranscript += text
                        self.volatileTranscript = ""
                        logger.debug("Finalized: \(text)")
                    } else {
                        self.volatileTranscript = text
                        logger.debug("Volatile: \(text)")
                    }
                }
            } catch {
                if !Task.isCancelled {
                    logger.error("Results stream error: \(error.localizedDescription)")
                }
            }
        }
    }
}

// MARK: - Audio Engine Helper

/// Nonisolated helper to handle audio engine setup without MainActor isolation.
/// This prevents Swift concurrency issues when the audio tap callback runs on the audio thread.
private enum AudioEngineHelper {
    
    static func startEngine(
        inputBuilder: AsyncStream<AnalyzerInput>.Continuation,
        targetFormat: AVAudioFormat?
    ) throws -> (AVAudioEngine, AsyncStream<Float>) {
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        
        // Create format converter if needed
        let converter: AVAudioConverter?
        if let targetFormat, inputFormat != targetFormat {
            converter = AVAudioConverter(from: inputFormat, to: targetFormat)
        } else {
            converter = nil
        }
        
        // Create audio level stream
        let (levelStream, levelContinuation) = AsyncStream<Float>.makeStream()
        
        // Install tap - this closure runs on the audio thread
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { buffer, _ in
            // Calculate audio level (RMS)
            if let channelData = buffer.floatChannelData?[0] {
                let frameLength = Int(buffer.frameLength)
                var sum: Float = 0
                for i in 0..<frameLength {
                    let sample = channelData[i]
                    sum += sample * sample
                }
                let rms = sqrt(sum / Float(frameLength))
                // Convert to 0-1 range with amplification for sensitivity
                let level = min(1.0, rms * 25.0)
                levelContinuation.yield(level)
            }
            
            let outputBuffer: AVAudioPCMBuffer
            
            if let converter, let targetFormat {
                // Convert buffer to target format
                let frameCapacity = AVAudioFrameCount(
                    Double(buffer.frameLength) * targetFormat.sampleRate / inputFormat.sampleRate
                )
                guard let converted = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: frameCapacity) else {
                    return
                }
                
                var error: NSError?
                converter.convert(to: converted, error: &error) { _, outStatus in
                    outStatus.pointee = .haveData
                    return buffer
                }
                
                if error != nil {
                    return
                }
                outputBuffer = converted
            } else {
                outputBuffer = buffer
            }
            
            let input = AnalyzerInput(buffer: outputBuffer)
            inputBuilder.yield(input)
        }
        
        engine.prepare()
        try engine.start()
        
        return (engine, levelStream)
    }
}
