import Foundation
import Vision
import Vapor

// MARK: - Request Models

struct ScanRequest: Content {
    let imageBase64: String
    let config: MutationConfig?
}

struct BatchScanRequest: Content {
    let images: [BatchImage]
    let config: MutationConfig?
}

struct BatchImage: Content {
    let id: String
    let imageBase64: String
}

// MARK: - Mutation Config

struct MutationConfig: Content {
    let scales: [Double]?
    let brightnessDeltas: [Double]?
    let contrastDeltas: [Double]?
    let blurRadii: [Double]?
    let rotationDegrees: [Double]?
    let sharpenIntensities: [Double]?

    // Default — catches hard-to-read QRs while staying under 1s (~60 mutations)
    static let `default` = MutationConfig(
        scales:             [0.75, 1.0, 1.5],
        brightnessDeltas:   [-0.3, -0.15, 0.0, 0.15, 0.3],
        contrastDeltas:     [-0.1, 0.0],
        blurRadii:          [0.0, 1.0],
        rotationDegrees:    [0.0],
        sharpenIntensities: [0.0]
    )

    // Heavy — full sweep across all mutation axes (~6,000 mutations)
    static let heavy = MutationConfig(
        scales:             [0.5, 0.75, 1.0, 1.25, 1.5, 2.0],
        brightnessDeltas:   [-0.3, -0.15, 0.0, 0.15, 0.3],
        contrastDeltas:     [-0.1, 0.0, 0.15, 0.3],
        blurRadii:          [0.0, 0.5, 1.0, 1.5],
        rotationDegrees:    [-5.0, -2.0, 0.0, 2.0, 5.0],
        sharpenIntensities: [0.0, 0.3, 0.7]
    )

    var resolvedScales:             [Double] { scales             ?? MutationConfig.default.scales! }
    var resolvedBrightnessDeltas:   [Double] { brightnessDeltas   ?? MutationConfig.default.brightnessDeltas! }
    var resolvedContrastDeltas:     [Double] { contrastDeltas     ?? MutationConfig.default.contrastDeltas! }
    var resolvedBlurRadii:          [Double] { blurRadii          ?? MutationConfig.default.blurRadii! }
    var resolvedRotationDegrees:    [Double] { rotationDegrees    ?? MutationConfig.default.rotationDegrees! }
    var resolvedSharpenIntensities: [Double] { sharpenIntensities ?? MutationConfig.default.sharpenIntensities! }

    var totalMutationCount: Int {
        resolvedScales.count *
        resolvedBrightnessDeltas.count *
        resolvedContrastDeltas.count *
        resolvedBlurRadii.count *
        resolvedRotationDegrees.count *
        resolvedSharpenIntensities.count
    }

    // MARK: - Validation

    static let maxValuesPerDimension = 10
    static let maxTotalMutations = 10_000

    func validated() throws -> MutationConfig {
        let dimensions: [(String, [Double]?)] = [
            ("scales", scales),
            ("brightnessDeltas", brightnessDeltas),
            ("contrastDeltas", contrastDeltas),
            ("blurRadii", blurRadii),
            ("rotationDegrees", rotationDegrees),
            ("sharpenIntensities", sharpenIntensities),
        ]

        for (name, values) in dimensions {
            if let values, values.count > Self.maxValuesPerDimension {
                throw ConfigValidationError.dimensionTooLarge(name: name, count: values.count, max: Self.maxValuesPerDimension)
            }
        }

        if totalMutationCount > Self.maxTotalMutations {
            throw ConfigValidationError.totalMutationsExceeded(count: totalMutationCount, max: Self.maxTotalMutations)
        }

        if let scales, scales.contains(where: { $0 <= 0.0 || $0 > 5.0 }) {
            throw ConfigValidationError.valueOutOfRange(name: "scales", allowed: "0.0 < scale <= 5.0")
        }
        if let blurRadii, blurRadii.contains(where: { $0 < 0.0 || $0 > 10.0 }) {
            throw ConfigValidationError.valueOutOfRange(name: "blurRadii", allowed: "0.0 <= radius <= 10.0")
        }

        return self
    }
}

enum ConfigValidationError: Error, LocalizedError {
    case dimensionTooLarge(name: String, count: Int, max: Int)
    case totalMutationsExceeded(count: Int, max: Int)
    case valueOutOfRange(name: String, allowed: String)

    var errorDescription: String? {
        switch self {
        case .dimensionTooLarge(let name, let count, let max):
            return "Config '\(name)' has \(count) values, max allowed is \(max)"
        case .totalMutationsExceeded(let count, let max):
            return "Total mutations (\(count)) exceeds max allowed (\(max))"
        case .valueOutOfRange(let name, let allowed):
            return "Config '\(name)' contains out-of-range values. Allowed: \(allowed)"
        }
    }
}

// MARK: - Detection Result

struct QRDetection: Codable {
    let payload: String
    let symbology: String
    let confidence: Float
    let boundingBox: BoundingBox
}

struct BoundingBox: Codable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double
}

// MARK: - Scan Report

struct ScanReport: Codable {
    let imageDimensions: ImageDimensions
    let mutationsTried: Int
    let detections: [QRDetection]
}

struct ImageDimensions: Codable {
    let width: Int
    let height: Int
}

// MARK: - Batch Response

struct BatchScanResponse: Content {
    let results: [BatchImageReport]
    let totalProcessed: Int
    let totalWithDetections: Int
}

struct BatchImageReport: Codable {
    let id: String
    let report: ScanReport
    let durationMs: Int
}
