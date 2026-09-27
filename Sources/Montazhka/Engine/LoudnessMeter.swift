import Foundation

/// Громкость по BS.1770-4 / EBU R128.
struct LoudnessMeasurement: Codable, Equatable, Sendable {
    /// nil — мерить нечего (тишина).
    let integratedLUFS: Double?
    let truePeakDBTP: Double
    let loudnessRangeLU: Double?
    let seconds: Double
}
