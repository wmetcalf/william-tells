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
    private static let rasterTypes: Set<String> = [
        UTType.png, .jpeg, .heic, .heif, .webP, .tiff, .gif, .bmp,
    ].reduce(into: Set<String>()) { $0.insert($1.identifier) }

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

    /// SVG only if the document's first element is `<svg`: after an optional BOM, whitespace,
    /// an XML declaration / processing instructions, comments and a DOCTYPE -- nothing else.
    /// (A substring test would send a PNG or PSD with "<svg" in a text chunk to NSImage, which
    /// auto-detects the real format and skips the raster allowlist and pixel limit.) Scans raw
    /// bytes over the whole input, so a long prolog still finds the root and no UTF-8 decoding
    /// (or a copy of a large image) is needed; a binary format fails on its first byte.
    static func isSVG(_ data: Data) -> Bool {
        // XML may also be UTF-16 (BOM, or `<` interleaved with NUL); transcode and scan that.
        if let utf8 = utf16AsUTF8(data) { return svgRoot(utf8) }
        return svgRoot(data)
    }

    /// UTF-16 XML (per the XML spec's encoding detection: a BOM, or `<?`/`<` with NUL bytes)
    /// as UTF-8, or nil when the input isn't UTF-16. Malformed UTF-16 is not SVG.
    static func utf16AsUTF8(_ data: Data) -> Data? {
        guard data.count >= 2 else { return nil }
        let b0 = data[data.startIndex], b1 = data[data.startIndex + 1]
        let enc: String.Encoding
        var body = data
        switch (b0, b1) {
        case (0xFF, 0xFE): enc = .utf16LittleEndian; body = data.dropFirst(2)
        case (0xFE, 0xFF): enc = .utf16BigEndian; body = data.dropFirst(2)
        case (0x3C, 0x00): enc = .utf16LittleEndian
        case (0x00, 0x3C): enc = .utf16BigEndian
        default: return nil
        }
        guard body.count % 2 == 0, let text = String(data: Data(body), encoding: enc) else {
            return Data()   // looked like UTF-16 but isn't valid: scanned as empty -> not SVG
        }
        return Data(text.utf8)
    }

    private static func svgRoot(_ data: Data) -> Bool {
        data.withUnsafeBytes { raw -> Bool in
            let b = raw.bindMemory(to: UInt8.self)
            var i = 0
            if b.count >= 3, b[0] == 0xEF, b[1] == 0xBB, b[2] == 0xBF { i = 3 }
            func at(_ s: String) -> Bool {
                let u = Array(s.utf8)
                guard i + u.count <= b.count else { return false }
                for k in 0..<u.count where b[i + k] != u[k] { return false }
                return true
            }
            func atDoctype() -> Bool {
                let u = Array("<!doctype".utf8)
                guard i + u.count <= b.count else { return false }
                for k in 0..<u.count where b[i + k] | (k >= 2 ? 0x20 : 0) != u[k] { return false }
                return true
            }
            func skip(past end: String) -> Bool {   // moves i just past `end`
                let u = Array(end.utf8)
                while i + u.count <= b.count {
                    if at(end) { i += u.count; return true }
                    i += 1
                }
                return false
            }
            while true {
                while i < b.count, [0x20, 0x09, 0x0A, 0x0D].contains(b[i]) { i += 1 }
                if at("<?") {
                    guard skip(past: "?>") else { return false }
                } else if at("<!--") {
                    guard skip(past: "-->") else { return false }
                } else if atDoctype() {
                    guard let end = doctypeEnd(b, from: i) else { return false }
                    i = end
                } else {
                    break
                }
            }
            guard at("<svg") else { return false }
            guard i + 4 < b.count else { return true }
            let next = b[i + 4]
            return next == UInt8(ascii: ">") || next == UInt8(ascii: "/")
                || [0x20, 0x09, 0x0A, 0x0D].contains(next)
        }
    }

    /// Just past a DOCTYPE's closing `>`, skipping an internal subset (`[ ... ]`, whose entity
    /// and element declarations have their own `>`), quoted literals, and comments and
    /// processing instructions inside the subset (which may contain `]` or `>`).
    private static func doctypeEnd(_ b: UnsafeBufferPointer<UInt8>, from start: Int) -> Int? {
        var quote: UInt8? = nil
        var depth = 0
        var i = start
        func at(_ s: String, _ j: Int) -> Bool {
            let u = Array(s.utf8)
            guard j + u.count <= b.count else { return false }
            for k in 0..<u.count where b[j + k] != u[k] { return false }
            return true
        }
        func past(_ end: String, from j: Int) -> Int? {
            var j = j
            let n = end.utf8.count
            while j + n <= b.count {
                if at(end, j) { return j + n }
                j += 1
            }
            return nil
        }
        while i < b.count {
            let c = b[i]
            if quote == nil, depth > 0, at("<!--", i) {
                guard let e = past("-->", from: i + 4) else { return nil }
                i = e
                continue
            }
            if quote == nil, depth > 0, at("<?", i) {
                guard let e = past("?>", from: i + 2) else { return nil }
                i = e
                continue
            }
            if let q = quote {
                if c == q { quote = nil }
            } else if c == UInt8(ascii: "\"") || c == UInt8(ascii: "'") {
                quote = c
            } else if c == UInt8(ascii: "[") {
                depth += 1
            } else if c == UInt8(ascii: "]") {
                depth = max(0, depth - 1)
            } else if c == UInt8(ascii: ">") && depth == 0 {
                return i + 1
            }
            i += 1
        }
        return nil
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
