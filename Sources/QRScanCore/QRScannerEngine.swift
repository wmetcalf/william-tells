import Foundation
import Vision
import AppKit
import CoreImage
import Metal
import ImageIO
import UniformTypeIdentifiers

// MARK: - Compute preference

/// Where Vision runs barcode detection. `.auto` lets Vision choose, which is what an iPhone does
/// and what the service has always used. The others exist so a self-test can prove a specific
/// accelerator is reachable (a sandbox missing a Neural Engine grant otherwise degrades to an
/// empty result, not an error).
public enum ComputePreference: String, Sendable, CaseIterable {
    case auto, ane, gpu, cpu
}

public enum ComputeError: Error, LocalizedError {
    case unavailable(ComputePreference)

    public var errorDescription: String? {
        switch self {
        case .unavailable(let pref):
            return "Vision reports no \(pref.rawValue) compute device for barcode detection on this host"
        }
    }
}

// MARK: - QR Scanner Engine

public actor QRScannerEngine {

    private let ciContext: CIContext
    private let metalDevice: MTLDevice?
    private let compute: ComputePreference

    public init(compute: ComputePreference = .auto) {
        self.compute = compute
        let device = MTLCreateSystemDefaultDevice()
        self.metalDevice = device
        if let device {
            self.ciContext = CIContext(mtlDevice: device, options: [
                .useSoftwareRenderer: false,
                .highQualityDownsample: true
            ])
        } else {
            self.ciContext = CIContext(options: [.useSoftwareRenderer: false])
        }
    }

    // MARK: - Public API

    public func scan(imageData: Data, config: MutationConfig, earlyExit: Bool = false) async throws -> ScanReport {
        let cgImage = try Self.loadImage(from: imageData)

        let dimensions = ImageDimensions(
            width: cgImage.width,
            height: cgImage.height
        )

        let (detections, mutationsTried) = try await runMutations(on: cgImage, config: config, earlyExit: earlyExit)

        return ScanReport(
            imageDimensions: dimensions,
            mutationsTried: mutationsTried,
            detections: detections
        )
    }

    // MARK: - Mutation Engine

    private func runMutations(
        on image: CGImage,
        config: MutationConfig,
        earlyExit: Bool
    ) async throws -> (detections: [QRDetection], mutationsTried: Int) {

        // 1. Try the raw image first — skip mutations entirely if we get results
        let initial = try scanWithVision(image)
        if !initial.isEmpty {
            return (initial, 0)
        }

        // 2. Nothing found on raw image — run mutations
        // Dedup key includes payload + approximate bbox so distinct QRs with the same
        // payload at different locations are preserved
        var seen = Set<String>()
        var detections: [QRDetection] = []
        var mutationsTried = 0

        for scale in config.resolvedScales {
            for brightness in config.resolvedBrightnessDeltas {
                for contrast in config.resolvedContrastDeltas {
                    for blur in config.resolvedBlurRadii {
                        for rotation in config.resolvedRotationDegrees {
                            for sharpen in config.resolvedSharpenIntensities {

                                if blur == 0.0 && sharpen > 0.0 { continue }

                                mutationsTried += 1

                                guard let mutated = applyMutation(to: image,
                                    scale: scale, brightness: brightness, contrast: contrast,
                                    blur: blur, rotation: rotation, sharpen: sharpen
                                ) else { continue }

                                let results = try scanWithVision(mutated)

                                var foundNew = false
                                for det in results {
                                    let key = "\(det.payload)|\(Int(det.boundingBox.x * 10))|\(Int(det.boundingBox.y * 10))"
                                    guard !seen.contains(key) else { continue }
                                    seen.insert(key)
                                    detections.append(det)
                                    foundNew = true
                                }

                                if earlyExit && foundNew { return (detections, mutationsTried) }
                            }
                        }
                    }
                }
            }
        }

        return (detections, mutationsTried)
    }

    // MARK: - Apply Mutations via CoreImage

    private func applyMutation(
        to image: CGImage,
        scale: Double, brightness: Double, contrast: Double,
        blur: Double, rotation: Double, sharpen: Double
    ) -> CGImage? {
        var ciImage = CIImage(cgImage: image)

        if scale != 1.0 {
            ciImage = ciImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        }

        if rotation != 0.0 {
            let radians = CGFloat(rotation * .pi / 180.0)
            ciImage = ciImage.transformed(by: CGAffineTransform(rotationAngle: radians))
        }

        if brightness != 0.0 || contrast != 0.0 {
            ciImage = ciImage.applyingFilter("CIColorControls", parameters: [
                kCIInputBrightnessKey: brightness,
                kCIInputContrastKey:   1.0 + contrast,
                kCIInputSaturationKey: 1.0
            ])
        }

        if blur > 0.0 {
            let preBlurExtent = ciImage.extent
            ciImage = ciImage.applyingFilter("CIGaussianBlur", parameters: [
                kCIInputRadiusKey: blur
            ])
            ciImage = ciImage.cropped(to: preBlurExtent)
        }

        if sharpen > 0.0 {
            ciImage = ciImage.applyingFilter("CISharpenLuminance", parameters: [
                kCIInputSharpnessKey: sharpen,
                kCIInputRadiusKey:    1.5
            ])
        }

        return ciContext.createCGImage(ciImage, from: ciImage.extent)
    }

    // MARK: - Vision Framework Scan

    private func scanWithVision(_ image: CGImage) throws -> [QRDetection] {
        var detections: [QRDetection] = []
        var scanError: Error?

        let request = VNDetectBarcodesRequest { request, error in
            if let error = error {
                scanError = error
                return
            }

            guard let results = request.results as? [VNBarcodeObservation] else { return }

            for obs in results {
                guard let payload = obs.payloadStringValue else { continue }

                detections.append(QRDetection(
                    payload: payload,
                    symbology: obs.symbology.rawValue,
                    confidence: obs.confidence,
                    boundingBox: BoundingBox(
                        x: obs.boundingBox.origin.x,
                        y: obs.boundingBox.origin.y,
                        width: obs.boundingBox.width,
                        height: obs.boundingBox.height
                    )
                ))
            }
        }

        request.symbologies = [
            VNBarcodeSymbology.qr,
            VNBarcodeSymbology.microQR,
            VNBarcodeSymbology.dataMatrix,
            VNBarcodeSymbology.pdf417,
            VNBarcodeSymbology.aztec,
            VNBarcodeSymbology.code128,
            VNBarcodeSymbology.code39,
            VNBarcodeSymbology.code93,
            VNBarcodeSymbology.ean8,
            VNBarcodeSymbology.ean13,
            VNBarcodeSymbology.upce,
            VNBarcodeSymbology.itf14,
            VNBarcodeSymbology.gs1DataBar,
            VNBarcodeSymbology.gs1DataBarExpanded,
            VNBarcodeSymbology.codabar
        ]

        request.usesCPUOnly = false
        try applyComputePreference(to: request)

        var options: [VNImageOption: Any] = [:]
        if let device = metalDevice {
            options[.ciContext] = CIContext(mtlDevice: device)
        }
        let handler = VNImageRequestHandler(cgImage: image, options: options)
        try handler.perform([request])

        if let error = scanError { throw error }

        return detections
    }

    private func applyComputePreference(to request: VNDetectBarcodesRequest) throws {
        guard compute != .auto else { return }
        guard #available(macOS 14.0, *) else { throw ComputeError.unavailable(compute) }
        let devices = try request.supportedComputeStageDevices[.main] ?? []
        let match = devices.first { device in
            switch (compute, device) {
            case (.ane, .neuralEngine), (.gpu, .gpu), (.cpu, .cpu): return true
            default: return false
            }
        }
        guard let match else { throw ComputeError.unavailable(compute) }
        request.setComputeDevice(match, for: .main)
    }

    /// The compute devices Vision offers for barcode detection here (for self-tests / doctor).
    public static func availableComputeDevices() -> [String] {
        guard #available(macOS 14.0, *) else { return [] }
        let devices = (try? VNDetectBarcodesRequest().supportedComputeStageDevices[.main]) ?? []
        return devices.map { device in
            switch device {
            case .neuralEngine: return "ane"
            case .gpu: return "gpu"
            case .cpu: return "cpu"
            @unknown default: return "other"
            }
        }
    }

    // MARK: - Image Loading (PNG, JPEG, HEIC, HEIF, TIFF, GIF, BMP, WebP, SVG, PDF)

    private static let vectorRasterSize: CGFloat = 2048

    /// Largest raster accepted, checked from the header BEFORE decoding (decompression bombs).
    public static let maxPixels = 100_000_000

    /// Raster types handed to ImageIO. Everything else ImageIO could parse (RAW, EXR, ICNS, PSD,
    /// TGA, …) is refused: each extra decoder is attack surface this service doesn't need.
    private static var rasterTypes: Set<String> { Set(rasterLabels.keys) }

    static func loadImage(from data: Data) throws -> CGImage {
        if isSVG(data) {
            guard let image = rasterizeSVG(data) else { throw ScanError.invalidImageData }
            return image
        }
        if isPDF(data) {
            guard let image = rasterizePDF(data) else { throw ScanError.invalidImageData }
            return image
        }

        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, options),
              let type = CGImageSourceGetType(source) as String?
        else { throw ScanError.invalidImageData }
        guard rasterTypes.contains(type) else { throw ScanError.unsupportedType(type) }
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, 0, options) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int,
              let height = props[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0
        else { throw ScanError.invalidImageData }
        guard width.multipliedReportingOverflow(by: height).overflow == false,
              width * height <= maxPixels
        else { throw ScanError.imageTooLarge(width: width, height: height) }
        guard let image = CGImageSourceCreateImageAtIndex(source, 0, options) else {
            throw ScanError.invalidImageData
        }
        return image
    }

    /// SVG only if the document's root element is `svg` in the SVG namespace (or unprefixed
    /// with no namespace, which NSImage also renders). Decided by Foundation's XMLParser --
    /// libxml2, the same parser NSImage's SVG path uses -- so encodings, character and entity
    /// references and DTD subsets are read exactly as the renderer reads them. It stops at the
    /// root, never resolves external entities, and libxml2 refuses entity-expansion bombs.
    /// (A substring test would send a PNG or PSD with "<svg" in a text chunk to NSImage, which
    /// auto-detects the real format and skips the raster allowlist and pixel limit.)
    static func isSVG(_ data: Data) -> Bool {
        let parser = XMLParser(data: data)
        let root = RootElement()
        parser.delegate = root
        parser.shouldProcessNamespaces = true
        parser.shouldReportNamespacePrefixes = false
        parser.shouldResolveExternalEntities = false
        _ = parser.parse()
        guard let r = root.found, r.local == "svg" else { return false }
        if r.namespace == svgNamespace { return true }
        return (r.namespace ?? "").isEmpty && r.qualified == "svg"
    }

    static let svgNamespace = "http://www.w3.org/2000/svg"

    private final class RootElement: NSObject, XMLParserDelegate {
        var found: (local: String, qualified: String?, namespace: String?)?
        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                    qualifiedName: String?, attributes: [String: String] = [:]) {
            found = (name, qualifiedName, namespaceURI)
            parser.abortParsing()
        }
    }

    /// Labels for the inputs the scanner accepts, with their MIME types: what the envelope's
    /// `detected` reports. The scanner (sandboxed, it already parses the input) decides the
    /// label; hosts only check it is one of these.
    public static let inputMIMEs: [String: String] = [
        "png": "image/png", "jpeg": "image/jpeg", "gif": "image/gif", "tiff": "image/tiff",
        "bmp": "image/bmp", "webp": "image/webp", "heic": "image/heic", "heif": "image/heif",
        "pdf": "application/pdf", "svg": "image/svg+xml",
    ]

    private static let rasterLabels: [String: String] = [
        UTType.png.identifier: "png", UTType.jpeg.identifier: "jpeg", UTType.gif.identifier: "gif",
        UTType.tiff.identifier: "tiff", UTType.bmp.identifier: "bmp", UTType.webP.identifier: "webp",
        UTType.heic.identifier: "heic", UTType.heif.identifier: "heif",
    ]

    /// The `inputMIMEs` label of an input the scanner would accept, by the same tests
    /// `loadImage` routes on; nil when it would be refused.
    public static func inputType(_ data: Data) -> String? {
        if isSVG(data) { return "svg" }
        if isPDF(data) { return "pdf" }
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, options),
              let type = CGImageSourceGetType(source) as String?
        else { return nil }
        return rasterLabels[type]
    }

    private static func isPDF(_ data: Data) -> Bool {
        return data.prefix(5) == Data("%PDF-".utf8)
    }

    private static func rasterizeSVG(_ data: Data) -> CGImage? {
        guard let nsImage = NSImage(data: data) else { return nil }
        let intrinsic = nsImage.size
        guard intrinsic.width > 0, intrinsic.height > 0 else { return nil }
        let scaleFactor = vectorRasterSize / max(intrinsic.width, intrinsic.height)
        return renderToImage(nsImage,
            width: Int(intrinsic.width * scaleFactor),
            height: Int(intrinsic.height * scaleFactor))
    }

    private static func rasterizePDF(_ data: Data) -> CGImage? {
        guard let provider = CGDataProvider(data: data as CFData),
              let pdf = CGPDFDocument(provider),
              let page = pdf.page(at: 1)
        else { return nil }

        let mediaBox = page.getBoxRect(.mediaBox)
        guard mediaBox.width > 0, mediaBox.height > 0 else { return nil }
        let scaleFactor = vectorRasterSize / max(mediaBox.width, mediaBox.height)
        let targetWidth = Int(mediaBox.width * scaleFactor)
        let targetHeight = Int(mediaBox.height * scaleFactor)

        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(
                  data: nil, width: targetWidth, height: targetHeight,
                  bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }

        ctx.setFillColor(CGColor.white)
        ctx.fill(CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))
        ctx.scaleBy(x: scaleFactor, y: scaleFactor)
        ctx.drawPDFPage(page)
        return ctx.makeImage()
    }

    private static func renderToImage(_ nsImage: NSImage, width: Int, height: Int) -> CGImage? {
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(
                  data: nil, width: width, height: height,
                  bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }

        ctx.setFillColor(CGColor.white)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))

        let nsCtx = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.current = nsCtx
        nsImage.draw(in: CGRect(x: 0, y: 0, width: width, height: height))
        NSGraphicsContext.current = nil
        return ctx.makeImage()
    }
}

// MARK: - Errors

public enum ScanError: Error, LocalizedError {
    case invalidImageData
    case unsupportedType(String)
    case imageTooLarge(width: Int, height: Int)

    public var errorDescription: String? {
        switch self {
        case .invalidImageData:
            return "Could not decode image data. Supported formats: PNG, JPEG, HEIC, SVG, PDF, WebP, TIFF, GIF, BMP."
        case .unsupportedType(let type):
            return "Unsupported image type \(type). Supported formats: PNG, JPEG, HEIC, SVG, PDF, WebP, TIFF, GIF, BMP."
        case .imageTooLarge(let width, let height):
            return "Image is \(width)x\(height) pixels; the limit is \(QRScannerEngine.maxPixels) pixels."
        }
    }
}
