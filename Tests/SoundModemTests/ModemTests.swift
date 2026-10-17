import XCTest
@testable import SoundModem

final class ModemTests: XCTestCase {
    private func feed(
        _ samples: [Float],
        to receiver: ModemReceiver,
        chunkSize: Int = 1024
    ) {
        var offset = 0
        while offset < samples.count {
            let count = min(chunkSize, samples.count - offset)
            receiver.feed(Array(samples[offset..<(offset + count)]))
            offset += count
        }
    }

    private func decode(
        _ message: String,
        sampleRate: Double,
        transform: (inout [Float]) -> Void = { _ in },
        chunkSize: Int = 1024
    ) throws -> [String] {
        var samples = try ModemEncoder(sampleRate: sampleRate).encode(message)
        transform(&samples)

        let receiver = ModemReceiver(sampleRate: sampleRate)
        var decoded: [String] = []
        receiver.onMessage = { decoded.append($0) }
        receiver.onDiagnostic = { message in
            print("diagnostic: \(message)")
        }
        feed(samples, to: receiver, chunkSize: chunkSize)
        return decoded
    }

    func testCRCKnownVector() {
        XCTAssertEqual(CRC16.checksum(Array("123456789".utf8)), 0x29B1)
    }

    func testRoundTrip48k() throws {
        let message = "Hello, acoustic world!"
        let decoded = try decode(message, sampleRate: 48_000)
        XCTAssertEqual(decoded, [message])
    }

    func testRoundTrip44k1WithChunking() throws {
        let message = "Swift + FSK @ 44.1 kHz"
        let decoded = try decode(
            message,
            sampleRate: 44_100,
            chunkSize: 317
        )
        XCTAssertEqual(decoded, [message])
    }

    func testUnicodePayload() throws {
        let message = "héllo 🌊 音声"
        let decoded = try decode(message, sampleRate: 48_000)
        XCTAssertEqual(decoded, [message])
    }

    func testNoisyEchoedChannel() throws {
        let message = "Through the air"
        var random = SmallRandom()
        let decoded = try decode(message, sampleRate: 48_000) { samples in
            let delay = Int(0.028 * 48_000)
            for index in samples.indices {
                samples[index] = 0.65 * samples[index] + random.noise() * 0.012
            }
            for index in stride(from: samples.count - 1, through: delay, by: -1) {
                samples[index] += 0.3 * samples[index - delay]
            }
        }
        XCTAssertEqual(decoded, [message])
    }

    func testResampledBetweenDevices() throws {
        let message = "different clocks"
        let original = try ModemEncoder(sampleRate: 48_000).encode(message)

        // Play at 48 kHz, capture at 44.1 kHz: the duration is the same but the
        // samples are on a different grid.
        let ratio = 44_100.0 / 48_000.0
        let count = Int((Double(original.count) * ratio).rounded())
        var resampled = [Float](repeating: 0, count: count)
        for index in 0..<count {
            let source = Double(index) / ratio
            let lower = Int(source)
            let upper = min(lower + 1, original.count - 1)
            let fraction = Float(source - Double(lower))
            resampled[index] = original[lower] * (1 - fraction) + original[upper] * fraction
        }

        let receiver = ModemReceiver(sampleRate: 44_100)
        var decoded: [String] = []
        receiver.onMessage = { decoded.append($0) }
        feed(resampled, to: receiver, chunkSize: 511)
        XCTAssertEqual(decoded, [message])
    }

    func testBandLimitedNoisyChannel() throws {
        let message = "speaker to microphone"
        var random = SmallRandom()
        let decoded = try decode(message, sampleRate: 48_000) { samples in
            let filtered = bandLimit(samples, sampleRate: 48_000)
            let delay = Int(0.022 * 48_000)
            for index in filtered.indices {
                samples[index] = 0.75 * filtered[index] + random.noise() * 0.03
            }
            for index in stride(from: samples.count - 1, through: delay, by: -1) {
                samples[index] += 0.25 * samples[index - delay]
            }
        }
        XCTAssertEqual(decoded, [message])
    }

    func testTwoConsecutiveFrames() throws {
        let rate = 48_000.0
        let encoder = ModemEncoder(sampleRate: rate)
        let first = "first message"
        let second = "second message"
        var samples = try encoder.encode(first)
        samples.append(contentsOf: [Float](repeating: 0, count: Int(0.2 * rate)))
        samples.append(contentsOf: try encoder.encode(second))

        let receiver = ModemReceiver(sampleRate: rate)
        var decoded: [String] = []
        receiver.onMessage = { decoded.append($0) }
        feed(samples, to: receiver, chunkSize: 700)
        XCTAssertEqual(decoded, [first, second])
    }

    func testEmptyString() throws {
        let decoded = try decode("", sampleRate: 48_000)
        XCTAssertEqual(decoded, [""])
    }

    func testMaximumPayload() throws {
        let message = String(repeating: "a", count: 255)
        let decoded = try decode(message, sampleRate: 48_000)
        XCTAssertEqual(decoded, [message])
    }

    func testRejectsTooLongPayload() {
        let encoder = ModemEncoder(sampleRate: 48_000)
        let message = String(repeating: "x", count: 256)
        XCTAssertThrowsError(try encoder.encode(message)) { error in
            guard case ModemError.payloadTooLong(let actual, let maximum) = error else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertEqual(actual, 256)
            XCTAssertEqual(maximum, 255)
        }
    }
}

private struct SmallRandom {
    var state: UInt64 = 0x1234_5678_9ABC_DEF0

    mutating func unit() -> Float {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return Float(Double(state >> 11) / Double(UInt64(1) << 53))
    }

    mutating func noise() -> Float {
        unit() - 0.5
    }
}

/// First-order high-pass and low-pass filters, roughly modelling the response
/// of a laptop speaker and microphone.
private func bandLimit(_ samples: [Float], sampleRate: Double) -> [Float] {
    let dt = 1.0 / sampleRate

    let highCutoff = 300.0
    let highRC = 1.0 / (2.0 * Double.pi * highCutoff)
    let highAlpha = Float(highRC / (highRC + dt))

    let lowCutoff = 5_000.0
    let lowRC = 1.0 / (2.0 * Double.pi * lowCutoff)
    let lowAlpha = Float(dt / (lowRC + dt))

    var previousInput: Float = 0
    var highOutput: Float = 0
    var lowOutput: Float = 0

    return samples.map { sample in
        highOutput = highAlpha * (highOutput + sample - previousInput)
        previousInput = sample
        lowOutput += lowAlpha * (highOutput - lowOutput)
        return lowOutput
    }
}
