import AVFoundation
import Dispatch
import Foundation
import SoundModem

#if canImport(Darwin)
import Darwin
#endif

private let arguments = Array(CommandLine.arguments.dropFirst())

private func writeStandardError(_ text: String) {
    FileHandle.standardError.write(Data((text + "\n").utf8))
}

private func fail(_ message: String, code: Int32 = 1) -> Never {
    writeStandardError("sound: \(message)")
    exit(code)
}

private func printUsage(toStdout: Bool = false) {
    let text = """
    sound - send strings between a speaker and a microphone

    USAGE:
      sound send <message>       Encode <message> and play it through the default output.
      sound listen               Decode microphone audio; print each string to stdout.
      sound loopback <message>   Play and listen simultaneously; print what the mic hears.
      sound selftest [message]   Run an in-memory round trip (no audio hardware).
      sound help                 Show this help.

    The message may be up to 255 UTF-8 bytes. Both the sender and receiver use
    16-FSK tones between 1 kHz and 4 kHz at 100 bits per second.
    """
    if toStdout {
        print(text)
        fflush(stdout)
    } else {
        writeStandardError(text)
    }
}

private func microphoneIsAuthorized() -> Bool {
    switch AVCaptureDevice.authorizationStatus(for: .audio) {
    case .authorized:
        return true
    case .notDetermined:
        let semaphore = DispatchSemaphore(value: 0)
        var granted = false
        AVCaptureDevice.requestAccess(for: .audio) { allowed in
            granted = allowed
            semaphore.signal()
        }
        if semaphore.wait(timeout: .now() + 60) == .timedOut {
            return false
        }
        return granted
    default:
        return false
    }
}

private func requireMicrophone() {
    guard microphoneIsAuthorized() else {
        fail(
            "microphone access is not permitted. Allow it in " +
            "System Settings > Privacy & Security > Microphone and try again."
        )
    }
}

private func makeSession(enableInput: Bool, enableOutput: Bool) throws -> AudioSession {
    let session = try AudioSession(enableInput: enableInput, enableOutput: enableOutput)
    session.onText = { text in
        print(text)
        fflush(stdout)
    }
    session.onDiagnostic = { message in
        writeStandardError("sound: \(message)")
    }
    return session
}

private final class ResultBox {
    private let lock = NSLock()
    private var stored: String?

    func store(_ text: String) {
        lock.lock()
        if stored == nil { stored = text }
        lock.unlock()
    }

    var value: String? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}

private func runSend(message: String) throws {
    let session = try makeSession(enableInput: false, enableOutput: true)
    try session.start()
    defer { session.stop() }

    writeStandardError(
        "sound: sending \(message.utf8.count) byte(s) through the default output"
    )

    let encoder = ModemEncoder(sampleRate: session.outputSampleRate)
    let samples = try encoder.encode(message)

    let finished = DispatchSemaphore(value: 0)
    try session.play(samples) { finished.signal() }

    let timeout = Double(samples.count) / session.outputSampleRate + 5
    if finished.wait(timeout: .now() + timeout) == .timedOut {
        fail("playback timed out")
    }
}

private func runListen() throws {
    requireMicrophone()
    let session = try makeSession(enableInput: true, enableOutput: false)
    try session.start()

    writeStandardError(
        "sound: listening on the default microphone at " +
        "\(Int(session.inputSampleRate)) Hz (Ctrl-C to stop)"
    )

    dispatchMain()
}

private func runLoopback(message: String) throws {
    requireMicrophone()
    let session = try makeSession(enableInput: true, enableOutput: true)

    let box = ResultBox()
    let decoded = DispatchSemaphore(value: 0)
    session.onText = { text in
        box.store(text)
        print(text)
        fflush(stdout)
        decoded.signal()
    }

    let encoder = ModemEncoder(sampleRate: session.outputSampleRate)
    let samples = try encoder.encode(message)
    let duration = Double(samples.count) / session.outputSampleRate

    try session.start()
    defer { session.stop() }

    writeStandardError(
        "sound: loopback: \(Int(session.outputSampleRate)) Hz out, " +
        "\(Int(session.inputSampleRate)) Hz in; message is \(message.utf8.count) byte(s)"
    )

    // Let the receiver finish its noise-floor calibration before transmitting.
    Thread.sleep(forTimeInterval: 0.65)
    try session.play(samples)

    if decoded.wait(timeout: .now() + duration + 8) == .timedOut {
        fail("loopback: the microphone did not decode a frame")
    }

    if let heard = box.value, heard != message {
        writeStandardError("sound: warning: decoded text differs from the transmitted text")
        exit(2)
    }
}

private struct SmallRandom {
    var state: UInt64 = 0x9E37_79B9_7F4A_7C15

    mutating func unit() -> Float {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return Float(Double(state >> 11) / Double(UInt64(1) << 53))
    }

    mutating func noise() -> Float {
        unit() - 0.5
    }
}

private func runSelfTest(message: String) throws {
    let sampleRate = 48_000.0
    var samples = try ModemEncoder(sampleRate: sampleRate).encode(message)

    // A small amount of noise plus an echo, to make the round trip a little
    // more realistic than a pure digital loop.
    var random = SmallRandom()
    for index in samples.indices {
        samples[index] += random.noise() * 0.004
    }
    let echoDelay = Int(0.03 * sampleRate)
    if samples.count > echoDelay {
        for index in stride(from: samples.count - 1, through: echoDelay, by: -1) {
            samples[index] += 0.28 * samples[index - echoDelay]
        }
    }

    let receiver = ModemReceiver(sampleRate: sampleRate)
    var received: String?
    var diagnostics = 0
    receiver.onMessage = { received = $0 }
    receiver.onDiagnostic = { _ in diagnostics += 1 }

    var offset = 0
    while offset < samples.count {
        let count = min(512, samples.count - offset)
        receiver.feed(Array(samples[offset..<(offset + count)]))
        offset += count
    }

    if let received, received == message {
        print(received)
        fflush(stdout)
        if diagnostics > 0 {
            writeStandardError("sound: selftest completed with \(diagnostics) diagnostic(s)")
        }
    } else {
        fail("selftest failed to recover the message")
    }
}

private func run() throws {
    guard let command = arguments.first else {
        printUsage()
        exit(1)
    }

    switch command {
    case "send":
        let message = arguments.dropFirst().joined(separator: " ")
        guard !message.isEmpty else {
            fail("usage: sound send <message>")
        }
        try runSend(message: message)

    case "listen":
        try runListen()

    case "loopback":
        let message = arguments.dropFirst().joined(separator: " ")
        guard !message.isEmpty else {
            fail("usage: sound loopback <message>")
        }
        try runLoopback(message: message)

    case "selftest":
        let message = arguments.dropFirst().joined(separator: " ")
        try runSelfTest(message: message.isEmpty ? "hello from the acoustic modem" : message)

    case "help", "--help", "-h":
        printUsage(toStdout: true)

    default:
        fail("unknown command '\(command)' (try: sound help)")
    }
}

do {
    try run()
} catch {
    fail("\(error)")
}
