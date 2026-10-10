import Foundation

// MARK: - Mutation Config

public struct MutationConfig: Codable, Sendable {
    public let scales: [Double]?
    public let brightnessDeltas: [Double]?
    public let contrastDeltas: [Double]?
    public let blurRadii: [Double]?
    public let rotationDegrees: [Double]?
    public let sharpenIntensities: [Double]?

    public init(
        scales: [Double]? = nil,
        brightnessDeltas: [Double]? = nil,
        contrastDeltas: [Double]? = nil,
        blurRadii: [Double]? = nil,
        rotationDegrees: [Double]? = nil,
        sharpenIntensities: [Double]? = nil
    ) {
        self.scales = scales
        self.brightnessDeltas = brightnessDeltas
        self.contrastDeltas = contrastDeltas
        self.blurRadii = blurRadii
        self.rotationDegrees = rotationDegrees
        self.sharpenIntensities = sharpenIntensities
    }

    // Default — catches hard-to-read QRs while staying under 1s (~60 mutations)
    public static let `default` = MutationConfig(
        scales:             [0.75, 1.0, 1.5],
        brightnessDeltas:   [-0.3, -0.15, 0.0, 0.15, 0.3],
        contrastDeltas:     [-0.1, 0.0],
        blurRadii:          [0.0, 1.0],
        rotationDegrees:    [0.0],
        sharpenIntensities: [0.0]
    )

    // Heavy — full sweep across all mutation axes (~6,000 mutations)
    public static let heavy = MutationConfig(
        scales:             [0.5, 0.75, 1.0, 1.25, 1.5, 2.0],
        brightnessDeltas:   [-0.3, -0.15, 0.0, 0.15, 0.3],
        contrastDeltas:     [-0.1, 0.0, 0.15, 0.3],
        blurRadii:          [0.0, 0.5, 1.0, 1.5],
        rotationDegrees:    [-5.0, -2.0, 0.0, 2.0, 5.0],
        sharpenIntensities: [0.0, 0.3, 0.7]
    )

    public var resolvedScales:             [Double] { scales             ?? MutationConfig.default.scales! }
    public var resolvedBrightnessDeltas:   [Double] { brightnessDeltas   ?? MutationConfig.default.brightnessDeltas! }
    public var resolvedContrastDeltas:     [Double] { contrastDeltas     ?? MutationConfig.default.contrastDeltas! }
    public var resolvedBlurRadii:          [Double] { blurRadii          ?? MutationConfig.default.blurRadii! }
    public var resolvedRotationDegrees:    [Double] { rotationDegrees    ?? MutationConfig.default.rotationDegrees! }
    public var resolvedSharpenIntensities: [Double] { sharpenIntensities ?? MutationConfig.default.sharpenIntensities! }

    public var totalMutationCount: Int {
        resolvedScales.count *
        resolvedBrightnessDeltas.count *
        resolvedContrastDeltas.count *
        resolvedBlurRadii.count *
        resolvedRotationDegrees.count *
        resolvedSharpenIntensities.count
    }

    // MARK: - Validation

    public static let maxValuesPerDimension = 10
    public static let maxTotalMutations = 10_000

    public func validated() throws -> MutationConfig {
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
            if let values, values.contains(where: { !$0.isFinite }) {
                throw ConfigValidationError.valueOutOfRange(name: name, allowed: "finite numbers")
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

public enum ConfigValidationError: Error, LocalizedError {
    case dimensionTooLarge(name: String, count: Int, max: Int)
    case totalMutationsExceeded(count: Int, max: Int)
    case valueOutOfRange(name: String, allowed: String)

    public var errorDescription: String? {
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

public struct QRDetection: Codable, Sendable {
    public let payload: String
    public let symbology: String
    public let confidence: Float
    public let boundingBox: BoundingBox
}

public struct BoundingBox: Codable, Sendable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double
}

// MARK: - Scan Report

public struct ScanReport: Codable, Sendable {
    public let imageDimensions: ImageDimensions
    public let mutationsTried: Int
    public let detections: [QRDetection]
}

public struct ImageDimensions: Codable, Sendable {
    public let width: Int
    public let height: Int
}
