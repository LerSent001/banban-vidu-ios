import Foundation

// Twelve real frequency bands, mirrored by the view around the center bar.
final class VoiceSpectrum: @unchecked Sendable {
    static let frequencies: [Double] = [240, 330, 460, 620, 830, 1100, 1450, 1900, 2450, 3100, 3900, 4800]
    private let coefficients: [Double]
    init(sampleRate: Double) {
        coefficients = Self.frequencies.map { 2 * cos(2 * .pi * $0 / sampleRate) }
    }
    func levels(_ samples: UnsafeBufferPointer<Float>) -> [Double] {
        guard !samples.isEmpty else { return Array(repeating: 0, count: coefficients.count) }
        return coefficients.map { coefficient in
            var first = 0.0, second = 0.0
            for sample in samples {
                let next = Double(sample) + coefficient * first - second
                second = first; first = next
            }
            let amplitude = 2 * sqrt(max(0, first * first + second * second - coefficient * first * second)) / Double(samples.count)
            return max(0, min(1, (20 * log10(max(amplitude, 0.000001)) + 62) / 46))
        }
    }
}
