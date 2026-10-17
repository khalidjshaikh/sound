import AVFoundation

public enum AudioError: Error, CustomStringConvertible {
    case noOutputDevice
    case noInputDevice
    case unsupportedInputFormat(String)
    case engineNotRunning
    case engine(String)
    case playback(String)

    public var description: String {
        switch self {
        case .noOutputDevice:
            return "no audio output device is available"
        case .noInputDevice:
            return "no audio input device is available"
        case let .unsupportedInputFormat(format):
            return "the microphone uses an unsupported sample format: \(format)"
        case .engineNotRunning:
            return "the audio engine is not running"
        case let .engine(message):
            return "could not start audio: \(message)"
        case let .playback(message):
            return "could not play audio: \(message)"
        }
    }
}

/// Wraps AVAudioEngine for the two directions used by the modem.
///
/// Output playback and microphone capture can be enabled independently, or
/// together for a speaker-to-microphone loopback.
public final class AudioSession {
    private let engine = AVAudioEngine()
    private let decoderQueue = DispatchQueue(label: "sound.modem.decoder")
    private let hasInput: Bool
    private let hasOutput: Bool

    private var player: AVAudioPlayerNode?
    private var playerFormat: AVAudioFormat?
    private var receiver: ModemReceiver?
    private var inputTapInstalled = false

    public private(set) var inputSampleRate: Double = 0
    public private(set) var outputSampleRate: Double = 0

    /// Called on a background queue with decoded strings.
    public var onText: ((String) -> Void)?

    /// Called on a background queue with non-fatal diagnostics.
    public var onDiagnostic: ((String) -> Void)?

    public init(enableInput: Bool, enableOutput: Bool) throws {
        self.hasInput = enableInput
        self.hasOutput = enableOutput

        if enableOutput {
            let outputFormat = engine.outputNode.inputFormat(forBus: 0)
            guard outputFormat.sampleRate > 0 else {
                throw AudioError.noOutputDevice
            }
            outputSampleRate = outputFormat.sampleRate

            let node = AVAudioPlayerNode()
            engine.attach(node)
            guard let mono = AVAudioFormat(
                standardFormatWithSampleRate: outputFormat.sampleRate,
                channels: 1
            ) else {
                throw AudioError.playback("could not create a mono output format")
            }
            engine.connect(node, to: engine.mainMixerNode, format: mono)
            player = node
            playerFormat = mono
        }

        if enableInput {
            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else {
                throw AudioError.noInputDevice
            }
            guard format.commonFormat == .pcmFormatFloat32 else {
                throw AudioError.unsupportedInputFormat(format.description)
            }
            inputSampleRate = format.sampleRate

            let modem = ModemReceiver(sampleRate: format.sampleRate)
            modem.onMessage = { [weak self] text in
                self?.onText?(text)
            }
            modem.onDiagnostic = { [weak self] message in
                self?.onDiagnostic?(message)
            }
            receiver = modem

            input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
                guard let self,
                      let channel = buffer.floatChannelData?[0] else {
                    return
                }

                let frameLength = Int(buffer.frameLength)
                guard frameLength > 0 else { return }

                let samples: [Float]
                if buffer.format.isInterleaved {
                    let channels = Int(buffer.format.channelCount)
                    var extracted = [Float](repeating: 0, count: frameLength)
                    for index in 0..<frameLength {
                        extracted[index] = channel[index * channels]
                    }
                    samples = extracted
                } else {
                    samples = Array(UnsafeBufferPointer(start: channel, count: frameLength))
                }

                self.decoderQueue.async { [weak self] in
                    self?.receiver?.feed(samples)
                }
            }
            inputTapInstalled = true
        }
    }

    deinit {
        stop()
    }

    public func start() throws {
        guard !engine.isRunning else { return }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            throw AudioError.engine(error.localizedDescription)
        }
    }

    /// Play mono float samples at this session's output sample rate.
    public func play(_ samples: [Float], completion: (() -> Void)? = nil) throws {
        guard hasOutput, let player, let format = playerFormat else {
            throw AudioError.noOutputDevice
        }
        guard engine.isRunning else {
            throw AudioError.engineNotRunning
        }
        guard !samples.isEmpty else {
            completion?()
            return
        }

        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(samples.count)
        ), let channel = buffer.floatChannelData?[0] else {
            throw AudioError.playback("could not allocate a playback buffer")
        }

        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in
            channel.update(from: source.baseAddress!, count: samples.count)
        }

        player.scheduleBuffer(
            buffer,
            at: nil,
            options: [],
            completionCallbackType: .dataPlayedBack
        ) { _ in
            completion?()
        }

        if !player.isPlaying {
            player.play()
        }
    }

    public func stop() {
        if inputTapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            inputTapInstalled = false
        }
        player?.stop()
        if engine.isRunning {
            engine.stop()
        }
    }

    public var isRunning: Bool {
        engine.isRunning
    }

    public var capturesInput: Bool { hasInput }
    public var producesOutput: Bool { hasOutput }
}
