import Foundation

/// Streaming receiver for the 16-FSK acoustic modem.
///
/// Feed captured mono samples with `feed(_:)`; decoded messages are delivered
/// through `onMessage`. The receiver is not thread-safe, so call `feed` from a
/// single serial queue.
public final class ModemReceiver {
    public let parameters: ModemParameters

    /// Called with every successfully decoded, CRC-checked string.
    public var onMessage: ((String) -> Void)?

    /// Called with non-fatal information about dropped frames, etc.
    public var onDiagnostic: ((String) -> Void)?

    private let sampleRate: Double
    private let symbolSamples: Double

    private var buffer: [Float] = []
    private var bufferStart = 0
    private var scanIndex = 0
    private var bufferEnd: Int { bufferStart + buffer.count }

    private var calibrated = false
    private let calibrationDuration = 0.3
    private var noiseFloor: Float = 1e-4

    private enum State {
        case searching
        case syncing(hint: Int)
        case decoding
    }
    private var state: State = .searching

    // Coarse onset detector state.
    private var loudStart: Int?
    private var loudRun = 0

    // Frame demodulator state.
    private var dataStartSample = 0
    private var symbolIndex = 0
    private var highNibble: UInt8?
    private var bytes: [UInt8] = []
    private var expectedBytes: Int?

    private var hannCache: [Int: [Double]] = [:]

    public init(parameters: ModemParameters) {
        self.parameters = parameters
        self.sampleRate = parameters.sampleRate
        self.symbolSamples = parameters.symbolLengthInSamples
    }

    public convenience init(sampleRate: Double) {
        self.init(parameters: ModemParameters(sampleRate: sampleRate))
    }

    /// Forget all buffered audio and search for a new frame.
    public func reset() {
        buffer.removeAll()
        bufferStart = 0
        scanIndex = 0
        calibrated = false
        noiseFloor = 1e-4
        state = .searching
        loudStart = nil
        loudRun = 0
        resetFrameState()
    }

    /// Submit captured mono samples. Chunk sizes may be arbitrary.
    public func feed(_ samples: [Float]) {
        guard !samples.isEmpty else { return }
        buffer.append(contentsOf: samples)
        process()
    }

    // MARK: - Pipeline

    private func process() {
        if !calibrated {
            let needed = Int((calibrationDuration * sampleRate).rounded())
            guard buffer.count >= needed else { return }
            calibrate(using: needed)
        }

        var working = true
        while working {
            switch state {
            case .searching:
                working = searchStep()
            case .syncing(let hint):
                working = syncStep(hint: hint)
            case .decoding:
                working = decodeStep()
            }
        }

        trim()
    }

    private func calibrate(using count: Int) {
        let window = max(1, Int((0.010 * sampleRate).rounded()))
        var levels: [Float] = []
        var offset = 0
        while offset + window <= count {
            levels.append(rms(at: offset, count: window))
            offset += window
        }

        if levels.isEmpty {
            noiseFloor = max(rms(at: 0, count: count), 1e-7)
        } else {
            levels.sort()
            // A low percentile ignores any sound that happened to be present
            // while the receiver was starting up.
            noiseFloor = max(levels[levels.count / 5], 1e-7)
        }

        calibrated = true
        scanIndex = 0
    }

    // MARK: - Searching

    private func searchStep() -> Bool {
        let window = max(1, Int((0.010 * sampleRate).rounded()))
        let hop = max(1, Int((0.005 * sampleRate).rounded()))
        let threshold = max(0.002, noiseFloor * 5)

        while scanIndex + window <= bufferEnd {
            let level = rms(at: scanIndex, count: window)

            if level > threshold {
                if loudStart == nil {
                    loudStart = scanIndex
                    loudRun = 1
                } else {
                    loudRun += 1
                }

                if loudRun >= 2 {
                    let hint = loudStart!
                    loudStart = nil
                    loudRun = 0
                    state = .syncing(hint: hint)
                    return true
                }
            } else {
                loudStart = nil
                loudRun = 0
                updateNoiseFloor(with: level)
            }

            scanIndex += hop
        }

        return false
    }

    private func updateNoiseFloor(with level: Float) {
        if level < noiseFloor {
            noiseFloor = 0.9 * noiseFloor + 0.1 * level
        } else if level < noiseFloor * 3 {
            noiseFloor = 0.995 * noiseFloor + 0.005 * level
        }
    }

    // MARK: - Synchronization

    private func syncStep(hint: Int) -> Bool {
        guard let onset = refineOnset(hint: hint) else {
            restAfterFailedSync(hint: hint)
            return true
        }

        let radius = max(1, Int((0.005 * sampleRate).rounded()))
        let step = max(1, Int((0.0005 * sampleRate).rounded()))
        let candidates = Array(stride(from: onset - radius, through: onset + radius, by: step))
        let preambleSamples = Int((Double(parameters.preamble.count) * symbolSamples).rounded())

        guard let last = candidates.last,
              last + preambleSamples <= bufferEnd else {
            return false
        }

        var bestStart: Int?
        var bestMatches = -1
        var bestQuality = -Double.infinity

        for start in candidates {
            let score = scorePreamble(start: start)
            if score.matches > bestMatches ||
                (score.matches == bestMatches && score.quality > bestQuality) {
                bestMatches = score.matches
                bestQuality = score.quality
                bestStart = start
            }
        }

        guard let start = bestStart,
              bestMatches >= parameters.preamble.count - 1 else {
            restAfterFailedSync(hint: hint)
            return true
        }

        dataStartSample = start + preambleSamples
        symbolIndex = 0
        highNibble = nil
        bytes = []
        expectedBytes = nil
        state = .decoding
        return true
    }

    private func restAfterFailedSync(hint: Int) {
        state = .searching
        scanIndex = max(scanIndex, hint + Int((0.05 * sampleRate).rounded()))
        loudStart = nil
        loudRun = 0
        resetFrameState()
    }

    /// Locate the first sample of the transmission more precisely than the
    /// coarse 10 ms energy detector. The encoder starts with a short fade-in,
    /// so the level crossing is within a couple of milliseconds of the true
    /// symbol boundary.
    private func refineOnset(hint: Int) -> Int? {
        let wall = max(1, Int((0.002 * sampleRate).rounded()))
        let hop = max(1, Int((0.0005 * sampleRate).rounded()))
        let begin = max(bufferStart, hint - Int((0.025 * sampleRate).rounded()))
        let end = min(bufferEnd, hint + Int((0.035 * sampleRate).rounded()))
        guard end - begin > wall else { return nil }

        var levels: [(sample: Int, level: Float)] = []
        var position = begin
        while position + wall <= end {
            levels.append((position, rms(at: position, count: wall)))
            position += hop
        }

        guard let peak = levels.map({ $0.level }).max(), peak > 0 else {
            return nil
        }

        let threshold = max(noiseFloor * 4, peak * 0.15)
        for entry in levels where entry.level > threshold {
            return entry.sample
        }
        return hint
    }

    private func scorePreamble(start: Int) -> (matches: Int, quality: Double) {
        let guardSamples = max(1, Int((parameters.guardDuration * sampleRate).rounded()))
        var matches = 0
        var quality = 0.0

        for (index, expected) in parameters.preamble.enumerated() {
            let symbolStart = start + Int((Double(index) * symbolSamples).rounded())
            let symbolEnd = start + Int((Double(index + 1) * symbolSamples).rounded())
            guard let tone = measureTones(
                start: symbolStart + guardSamples,
                end: symbolEnd - guardSamples
            ) else {
                return (0, 0)
            }

            if tone.nibble == expected {
                matches += 1
                quality += min(tone.ratio, 100)
            }
        }

        return (matches, quality)
    }

    // MARK: - Demodulation

    private func decodeStep() -> Bool {
        let guardSamples = max(1, Int((parameters.guardDuration * sampleRate).rounded()))
        let radius = max(1, Int((parameters.symbolSearchRadius * sampleRate).rounded()))
        let step = max(1, Int((0.001 * sampleRate).rounded()))

        while true {
            if let expected = expectedBytes, bytes.count >= expected {
                finishFrame()
                return true
            }

            let startExact = Double(symbolIndex) * symbolSamples
            let baseStart = dataStartSample + Int(startExact.rounded())
            let nextBoundary = dataStartSample + Int((startExact + symbolSamples).rounded())
            let windowStart = baseStart + guardSamples
            let windowEnd = nextBoundary - guardSamples

            guard windowEnd + radius < bufferEnd else {
                if frameTimedOut() {
                    onDiagnostic?("frame timed out; still searching")
                    abortFrame()
                    return true
                }
                return false
            }

            guard let tone = detectSymbol(
                windowStart: windowStart,
                windowEnd: windowEnd,
                radius: radius,
                step: step
            ) else {
                onDiagnostic?("unreadable symbol; frame dropped")
                abortFrame()
                return true
            }

            if let high = highNibble {
                bytes.append((high << 4) | tone.nibble)
                highNibble = nil
            } else {
                highNibble = tone.nibble
            }

            symbolIndex += 1

            if bytes.count == 1 && expectedBytes == nil {
                let length = Int(bytes[0])
                expectedBytes = 1 + length + 2
            }

            if let expected = expectedBytes, bytes.count >= expected {
                finishFrame()
                return true
            }
        }
    }

    /// Decode one symbol, allowing a small timing shift. Among windows that
    /// capture the same amount of tone energy, the one closest to the nominal
    /// grid position wins.
    private func detectSymbol(
        windowStart: Int,
        windowEnd: Int,
        radius: Int,
        step: Int
    ) -> ToneResult? {
        var measured: [(offset: Int, result: ToneResult)] = []
        var peak = 0.0

        var offset = -radius
        while offset <= radius {
            if let result = measureTones(
                start: windowStart + offset,
                end: windowEnd + offset
            ) {
                measured.append((offset, result))
                if result.best > peak { peak = result.best }
            }
            offset += step
        }

        guard peak > 0 else { return nil }
        let tolerance = peak * 0.98
        var chosen: (offset: Int, result: ToneResult)?

        for candidate in measured where candidate.result.best >= tolerance {
            if chosen == nil || abs(candidate.offset) < abs(chosen!.offset) {
                chosen = candidate
            }
        }

        return chosen?.result
    }

    private func frameTimedOut() -> Bool {
        let deadline: Int
        if let expected = expectedBytes {
            deadline = dataStartSample + Int((Double(expected * 2) * symbolSamples).rounded())
        } else {
            deadline = dataStartSample + Int((2.0 * symbolSamples).rounded())
        }
        return bufferEnd > deadline + Int((1.0 * sampleRate).rounded())
    }

    private func abortFrame() {
        let consumed = dataStartSample + Int((Double(symbolIndex) * symbolSamples).rounded())
        state = .searching
        scanIndex = max(scanIndex, consumed)
        resetFrameState()
    }

    private func finishFrame() {
        let frameBytes = bytes
        let symbolCount = expectedBytes.map { $0 * 2 } ?? (symbolIndex + 1)
        let frameEnd = dataStartSample + Int((Double(symbolCount) * symbolSamples).rounded())

        if let expected = expectedBytes, frameBytes.count >= expected {
            let length = Int(frameBytes[0])
            let bodyCount = 1 + length

            if frameBytes.count >= bodyCount + 2 {
                let receivedCRC = UInt16(frameBytes[bodyCount]) << 8 |
                    UInt16(frameBytes[bodyCount + 1])
                let computedCRC = CRC16.checksum(frameBytes[0..<bodyCount])

                if receivedCRC == computedCRC {
                    let payload = frameBytes[1..<bodyCount]
                    onMessage?(String(decoding: payload, as: UTF8.self))
                } else {
                    onDiagnostic?("CRC mismatch; frame dropped")
                }
            }
        }

        state = .searching
        scanIndex = max(scanIndex, frameEnd + Int((0.05 * sampleRate).rounded()))
        loudStart = nil
        loudRun = 0
        resetFrameState()
    }

    private func resetFrameState() {
        dataStartSample = 0
        symbolIndex = 0
        highNibble = nil
        bytes = []
        expectedBytes = nil
    }

    // MARK: - DSP helpers

    private struct ToneResult {
        let nibble: UInt8
        let best: Double
        let second: Double

        var ratio: Double {
            best / max(second, 1e-12)
        }
    }

    private func measureTones(start: Int, end: Int) -> ToneResult? {
        let length = end - start
        guard length > 32,
              start >= bufferStart,
              end <= bufferEnd else {
            return nil
        }

        let window = hannWindow(length: length)
        let base = start - bufferStart
        var energies = [Double](repeating: 0, count: ModemParameters.toneCount)
        let twoPi = 2.0 * Double.pi

        for tone in 0..<ModemParameters.toneCount {
            let frequency = parameters.frequency(forNibble: UInt8(tone))
            let omega = twoPi * frequency / sampleRate
            let coefficient = 2.0 * cos(omega)

            var previous = 0.0
            var previousPrevious = 0.0
            for index in 0..<length {
                let sample = Double(buffer[base + index]) * window[index]
                let current = sample + coefficient * previous - previousPrevious
                previousPrevious = previous
                previous = current
            }

            let energy = previous * previous + previousPrevious * previousPrevious -
                coefficient * previous * previousPrevious
            energies[tone] = max(energy, 0)
        }

        var bestIndex = 0
        for index in 1..<energies.count where energies[index] > energies[bestIndex] {
            bestIndex = index
        }

        var second = 0.0
        for index in 0..<energies.count where index != bestIndex {
            second = max(second, energies[index])
        }

        return ToneResult(
            nibble: UInt8(bestIndex),
            best: energies[bestIndex],
            second: second
        )
    }

    private func hannWindow(length: Int) -> [Double] {
        if let cached = hannCache[length] {
            return cached
        }

        var window = [Double](repeating: 0, count: length)
        let denominator = Double(max(length - 1, 1))
        let twoPi = 2.0 * Double.pi
        for index in 0..<length {
            window[index] = 0.5 - 0.5 * cos(twoPi * Double(index) / denominator)
        }
        hannCache[length] = window
        return window
    }

    private func rms(at start: Int, count: Int) -> Float {
        guard start >= bufferStart, start + count <= bufferEnd, count > 0 else {
            return 0
        }

        let base = start - bufferStart
        var sum: Float = 0
        for index in base..<(base + count) {
            let value = buffer[index]
            sum += value * value
        }
        return (sum / Float(count)).squareRoot()
    }

    // MARK: - Buffer management

    private func trim() {
        let guardSamples = Double(3) * symbolSamples
        let keepFrom: Int

        switch state {
        case .searching:
            keepFrom = scanIndex - Int((0.5 * sampleRate).rounded())
        case .syncing(let hint):
            keepFrom = hint - Int(guardSamples.rounded())
        case .decoding:
            keepFrom = dataStartSample - Int(guardSamples.rounded())
        }

        let drop = keepFrom - bufferStart
        guard drop > 0 else { return }

        let actual = min(drop, buffer.count)
        buffer.removeFirst(actual)
        bufferStart += actual

        if scanIndex < bufferStart {
            scanIndex = bufferStart
        }
    }
}
