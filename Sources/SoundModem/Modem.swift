import Foundation

public enum ModemError: Error, CustomStringConvertible {
    case payloadTooLong(actual: Int, maximum: Int)
    case invalidSampleRate(Double)

    public var description: String {
        switch self {
        case let .payloadTooLong(actual, maximum):
            return "message is \(actual) UTF-8 bytes; the limit is \(maximum)"
        case let .invalidSampleRate(rate):
            return "invalid audio sample rate: \(rate)"
        }
    }
}

/// Parameters of the acoustic modem.
///
/// The modem is a 16-tone frequency-shift keying (16-FSK) link. Each symbol
/// carries one nibble (4 bits) at 25 symbols/second, so the raw rate is
/// 100 bits/second. Frequencies and timing are expressed in hertz and
/// seconds, which makes the protocol independent of the audio sample rate.
public struct ModemParameters {
    public static let toneCount = 16
    public static let maximumPayloadBytes = 255

    public var sampleRate: Double

    /// Duration of one tone / one nibble.
    public var symbolDuration: Double = 0.040

    public var baseFrequency: Double = 1_000
    public var toneSpacing: Double = 200

    /// Known pattern used by the receiver to find the start of a frame.
    public var preamble: [UInt8] = [
        0xF, 0x0, 0xF, 0x0, 0xF, 0x0, 0xF, 0x0,
        0xE, 0x1, 0xD, 0x2,
    ]

    /// Silence before and after the modulated symbols.
    public var leadIn: Double = 0.4
    public var trailOut: Double = 0.25

    /// Peak amplitude of the generated waveform, 0...1.
    public var amplitude: Float = 0.5

    /// Unused samples at each edge of a symbol during demodulation.
    public var guardDuration: Double = 0.0025

    /// How far the demodulator may shift each symbol window to track timing.
    public var symbolSearchRadius: Double = 0.005

    public init(sampleRate: Double) {
        self.sampleRate = sampleRate
    }

    public var symbolLengthInSamples: Double {
        symbolDuration * sampleRate
    }

    public func frequency(forNibble nibble: UInt8) -> Double {
        baseFrequency + Double(nibble) * toneSpacing
    }
}

public struct ModemEncoder {
    public let parameters: ModemParameters

    public init(parameters: ModemParameters) {
        self.parameters = parameters
    }

    public init(sampleRate: Double) {
        self.parameters = ModemParameters(sampleRate: sampleRate)
    }

    /// Encode `text` as a sequence of mono Float32 samples at
    /// `parameters.sampleRate`, including leading and trailing silence.
    public func encode(_ text: String) throws -> [Float] {
        guard parameters.sampleRate.isFinite, parameters.sampleRate > 0 else {
            throw ModemError.invalidSampleRate(parameters.sampleRate)
        }

        let payload = Array(text.utf8)
        guard payload.count <= ModemParameters.maximumPayloadBytes else {
            throw ModemError.payloadTooLong(
                actual: payload.count,
                maximum: ModemParameters.maximumPayloadBytes
            )
        }

        // Frame: one length byte, the UTF-8 payload, and a big-endian CRC-16.
        var body = [UInt8(payload.count)]
        body.append(contentsOf: payload)
        let crc = CRC16.checksum(body)
        body.append(UInt8(crc >> 8))
        body.append(UInt8(crc & 0xFF))

        var symbols = parameters.preamble
        for byte in body {
            symbols.append(byte >> 4)
            symbols.append(byte & 0x0F)
        }

        let sampleRate = parameters.sampleRate
        let symbolSamples = parameters.symbolLengthInSamples
        let streamStart = Int((parameters.leadIn * sampleRate).rounded())
        let streamEnd = streamStart + Int((Double(symbols.count) * symbolSamples).rounded())
        let trailing = Int((parameters.trailOut * sampleRate).rounded())
        var samples = [Float](repeating: 0, count: streamEnd + trailing)

        let fadeSamples = max(1, Int((0.004 * sampleRate).rounded()))
        let twoPi = 2.0 * Double.pi
        var phase = 0.0

        for (index, nibble) in symbols.enumerated() {
            let start = streamStart + Int((Double(index) * symbolSamples).rounded())
            let end = streamStart + Int((Double(index + 1) * symbolSamples).rounded())
            let increment = twoPi * parameters.frequency(forNibble: nibble) / sampleRate

            for sampleIndex in start..<end {
                phase += increment
                if phase >= twoPi { phase -= twoPi }

                var value = sin(phase)
                let fromStart = sampleIndex - streamStart
                let fromEnd = (streamEnd - 1) - sampleIndex
                if fromStart < fadeSamples {
                    let t = Double(fromStart) / Double(fadeSamples)
                    value *= 0.5 - 0.5 * cos(Double.pi * t)
                }
                if fromEnd < fadeSamples {
                    let t = Double(fromEnd) / Double(fadeSamples)
                    value *= 0.5 - 0.5 * cos(Double.pi * t)
                }
                samples[sampleIndex] = parameters.amplitude * Float(value)
            }
        }

        return samples
    }
}
