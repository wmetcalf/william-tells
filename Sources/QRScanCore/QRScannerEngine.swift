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

    /// `deadline`: stop trying mutations once it passes and report what was found so far, with
    /// `budgetExhausted` set. A host that kills the scanner at a timeout passes one inside that
    /// timeout, so a long sweep ends with its partial result instead of being killed with nothing.
    public func scan(imageData: Data, config: MutationConfig, earlyExit: Bool = false,
                     deadline: Date? = nil) async throws -> ScanReport {
        let cgImage = try Self.loadImage(from: imageData)

        let dimensions = ImageDimensions(
            width: cgImage.width,
            height: cgImage.height
        )

        let (detections, mutationsTried, exhausted) = try runMutations(
            on: cgImage, config: config, earlyExit: earlyExit, deadline: deadline)

        return ScanReport(
            imageDimensions: dimensions,
            mutationsTried: mutationsTried,
            detections: detections,
            budgetExhausted: exhausted
        )
    }

    // MARK: - Mutation Engine

    /// Long side of the tiles the first pass scans at native resolution. Vision downsamples a
    /// large frame, so a photo of many small codes reads only a few of them whole (3 of 60 on a
    /// 12 MP test photo; 46-60 of 60 with these tiles).
    static let tileSize = 1024
    /// Tiles overlap by a quarter, so a code up to that size lies wholly inside some tile.
    static let tileStep = 768
    /// Images whose long side is at most this are not tiled (a tile would be most of the image).
    static let tileThreshold = 1536
    /// Largest image a mutation renders. Mutating a 48 MP photo at 2x would render ~190 MP
    /// (~770 MB per frame) for no gain: Vision downsamples it again. Scales are clamped so the
    /// output stays under this; scales that clamp to the same value run once.
    static let maxWorkingPixels = 4096 * 4096

    /// Axis stretches for a code photographed at a steep angle (foreshortened to a half or a
    /// third of its width or height): Vision gives up on it, but reads it once it is stretched
    /// back. (8 of 12 such misses on the BoofCV perspective set.)
    static let stretches: [(x: Double, y: Double)] = [(2, 1), (3, 1), (1, 2), (1, 3)]
    /// Most rectangles the perspective pass unwarps (Vision's rectangle detector, then
    /// CIPerspectiveCorrection): the paper or sticker a code is printed on is usually one.
    static let maxRectangles = 8
    /// Long side an unwarped rectangle is rendered at, at most (and at least, for small ones).
    static let unwarpMax = 2048
    static let unwarpMin = 600

    struct Mutation: Hashable {
        let scale: Double, brightness: Double, contrast: Double
        let blur: Double, rotation: Double, sharpen: Double
    }

    /// The config's mutations in the order they run: those in the default config first (so a
    /// sweep cut short by its deadline has at least tried what a default scan tries), then the
    /// rest in config order. Blur-free sharpening is skipped, as it always was; clamped
    /// duplicates are dropped.
    static func orderedMutations(_ config: MutationConfig, width: Int, height: Int) -> [Mutation] {
        let pixels = Double(width) * Double(height)
        let maxScale = (Double(maxWorkingPixels) / max(pixels, 1)).squareRoot()
        func product(_ c: MutationConfig) -> [Mutation] {
            var out: [Mutation] = []
            for scale in c.resolvedScales {
                for brightness in c.resolvedBrightnessDeltas {
                    for contrast in c.resolvedContrastDeltas {
                        for blur in c.resolvedBlurRadii {
                            for rotation in c.resolvedRotationDegrees {
                                for sharpen in c.resolvedSharpenIntensities {
                                    if blur == 0.0 && sharpen > 0.0 { continue }
                                    out.append(Mutation(scale: min(scale, maxScale), brightness: brightness,
                                                        contrast: contrast, blur: blur, rotation: rotation,
                                                        sharpen: sharpen))
                                }
                            }
                        }
                    }
                }
            }
            return out
        }
        let all = product(config)
        let preferred = Set(product(.default))
        var seen = Set<Mutation>()
        return (all.filter { preferred.contains($0) } + all.filter { !preferred.contains($0) })
            .filter { seen.insert($0).inserted }
    }

    /// Tile rects (pixel coordinates, top-left origin) covering the image, or [] when it is
    /// small enough to scan whole.
    static func tileRects(width: Int, height: Int) -> [CGRect] {
        guard max(width, height) > tileThreshold else { return [] }
        func starts(_ length: Int) -> [Int] {
            guard length > tileSize else { return [0] }
            var out = Array(stride(from: 0, to: length - tileSize, by: tileStep))
            out.append(length - tileSize)
            return out
        }
        return starts(height).flatMap { y in
            starts(width).map { x in
                CGRect(x: x, y: y, width: min(tileSize, width), height: min(tileSize, height))
            }
        }
    }

    /// Detections merged across passes. Two are the same code when the payload matches and
    /// their centers are within half a box of each other, so distinct codes with one payload
    /// at different places are all kept.
    struct DetectionSet {
        private(set) var items: [QRDetection] = []

        @discardableResult
        mutating func add(_ dets: [QRDetection]) -> Bool {
            var foundNew = false
            for d in dets where !items.contains(where: { Self.same($0, d) }) {
                items.append(d)
                foundNew = true
            }
            return foundNew
        }

        static func same(_ a: QRDetection, _ b: QRDetection) -> Bool {
            guard a.payload == b.payload else { return false }
            let (ab, bb) = (a.boundingBox, b.boundingBox)
            return abs((ab.x + ab.width / 2) - (bb.x + bb.width / 2)) < max(ab.width, bb.width) / 2
                && abs((ab.y + ab.height / 2) - (bb.y + bb.height / 2)) < max(ab.height, bb.height) / 2
        }
    }

    private func runMutations(
        on image: CGImage,
        config: MutationConfig,
        earlyExit: Bool,
        deadline: Date?
    ) throws -> (detections: [QRDetection], mutationsTried: Int, budgetExhausted: Bool) {
        func expired() -> Bool { deadline.map { Date() >= $0 } ?? false }
        var found = DetectionSet()

        // 1. The raw image, whole and in native-resolution tiles. Any hit here skips mutations.
        found.add(try scanWithVision(image))
        for rect in Self.tileRects(width: image.width, height: image.height) {
            if expired() { return (found.items, 0, true) }
            guard let tile = image.cropping(to: rect) else { continue }
            found.add(try scanWithVision(tile, symbologies: Self.tileSymbologies).map { Self.toFullImage($0, tile: rect, of: image) })
        }
        if !found.items.isEmpty {
            return (found.items, 0, false)
        }

        // 2. Nothing found on the raw image: undo a steep viewing angle (stretches, then unwarped
        // rectangles), then the brightness/contrast/... mutations — until the deadline. Every
        // view counts as a mutation tried.
        var mutationsTried = 0
        for view in perspectiveViews(of: image) {
            if expired() { return (found.items, mutationsTried, true) }
            mutationsTried += 1
            let foundNew = try autoreleasepool { () -> Bool in
                guard let (rendered, box) = view() else { return false }
                // Boxes in a stretched view are already in the image's normalized coordinates;
                // in an unwarped rectangle they are reported as that rectangle's bounds.
                return found.add(try scanWithVision(rendered).map { d in
                    box.map { QRDetection(payload: d.payload, symbology: d.symbology,
                                          confidence: d.confidence, boundingBox: $0) } ?? d
                })
            }
            if earlyExit && foundNew { return (found.items, mutationsTried, false) }
        }
        for m in Self.orderedMutations(config, width: image.width, height: image.height) {
            if expired() { return (found.items, mutationsTried, true) }
            mutationsTried += 1
            // Each mutation renders a full frame and Vision allocates per request; without a
            // pool per iteration those autoreleased buffers pile up until the sweep ends
            // (gigabytes on a large photo).
            let foundNew = try autoreleasepool { () -> Bool in
                guard let mutated = applyMutation(to: image,
                    scale: m.scale, brightness: m.brightness, contrast: m.contrast,
                    blur: m.blur, rotation: m.rotation, sharpen: m.sharpen
                ) else { return false }
                return found.add(try scanWithVision(mutated))
            }
            if earlyExit && foundNew { return (found.items, mutationsTried, false) }
        }

        return (found.items, mutationsTried, false)
    }

    /// Renderers for the perspective pass, run one at a time (each inside the caller's pool).
    /// A renderer returns the view, plus the box to report for its detections when the view's
    /// coordinates aren't the image's.
    private func perspectiveViews(of image: CGImage) -> [() -> (CGImage, BoundingBox?)?] {
        let source = CIImage(cgImage: image)
        let (w, h) = (Double(image.width), Double(image.height))
        var views: [() -> (CGImage, BoundingBox?)?] = Self.stretches.map { s in
            { [ciContext] in
                // Keep the stretched frame inside the working size.
                let k = min(1, (Double(Self.maxWorkingPixels) / (w * s.x * h * s.y)).squareRoot())
                let out = source.transformed(by: CGAffineTransform(scaleX: s.x * k, y: s.y * k))
                return ciContext.createCGImage(out, from: out.extent).map { ($0, nil) }
            }
        }
        let request = VNDetectRectanglesRequest()
        request.maximumObservations = Self.maxRectangles
        request.minimumAspectRatio = 0.1          // a square seen edge-on is a thin quad
        request.quadratureTolerance = 45
        request.minimumSize = 0.02
        request.minimumConfidence = 0.3
        // No rectangles is just no unwarped views; the stretches still run.
        let rects: [VNRectangleObservation] = autoreleasepool {
            (try? VNImageRequestHandler(cgImage: image, options: [:]).perform([request])) != nil
                ? Array((request.results ?? []).prefix(Self.maxRectangles)) : []
        }
        views += rects.map { o in
            { [ciContext] in
                func px(_ p: CGPoint) -> CIVector { CIVector(x: p.x * w, y: p.y * h) }
                let flat = source.applyingFilter("CIPerspectiveCorrection", parameters: [
                    "inputTopLeft": px(o.topLeft), "inputTopRight": px(o.topRight),
                    "inputBottomLeft": px(o.bottomLeft), "inputBottomRight": px(o.bottomRight)])
                guard flat.extent.width >= 1, flat.extent.height >= 1 else { return nil }
                // Square it up (the quad was a square seen at an angle), at a size Vision reads
                // well, on a white quiet zone.
                let side = min(Double(Self.unwarpMax), max(Double(Self.unwarpMin),
                                                           flat.extent.width, flat.extent.height))
                let pad = 40.0
                let square = flat
                    .transformed(by: CGAffineTransform(translationX: -flat.extent.minX, y: -flat.extent.minY))
                    .transformed(by: CGAffineTransform(scaleX: side / flat.extent.width,
                                                       y: side / flat.extent.height))
                    .transformed(by: CGAffineTransform(translationX: pad, y: pad))
                let page = square.composited(over: CIImage(color: .white)
                    .cropped(to: CGRect(x: 0, y: 0, width: side + 2 * pad, height: side + 2 * pad)))
                guard let cg = ciContext.createCGImage(page, from: page.extent) else { return nil }
                let b = o.boundingBox
                return (cg, BoundingBox(x: b.minX, y: b.minY, width: b.width, height: b.height))
            }
        }
        return views
    }

    /// A detection in a tile, with its box mapped to the whole image's normalized coordinates
    /// (Vision boxes have a bottom-left origin; tile rects are top-left).
    static func toFullImage(_ d: QRDetection, tile r: CGRect, of image: CGImage) -> QRDetection {
        let (w, h) = (Double(image.width), Double(image.height))
        let bb = d.boundingBox
        let bottom = h - Double(r.maxY)
        return QRDetection(
            payload: d.payload, symbology: d.symbology, confidence: d.confidence,
            boundingBox: BoundingBox(
                x: (Double(r.minX) + bb.x * Double(r.width)) / w,
                y: (bottom + bb.y * Double(r.height)) / h,
                width: bb.width * Double(r.width) / w,
                height: bb.height * Double(r.height) / h))
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

    /// Every symbology the scanner reports.
    static let allSymbologies: [VNBarcodeSymbology] = [
        .qr, .microQR, .dataMatrix, .pdf417, .aztec, .code128, .code39, .code93, .ean8, .ean13,
        .upce, .itf14, .gs1DataBar, .gs1DataBarExpanded, .codabar,
    ]
    /// The tiles look for QR codes only (what a phone camera acts on): asking Vision for every
    /// symbology roughly doubled the tile pass's cost (Data Matrix and Aztec most of it). The
    /// whole frame and every mutation still look for all of them.
    static let tileSymbologies: [VNBarcodeSymbology] = [.qr, .microQR]

    private func scanWithVision(_ image: CGImage,
                                symbologies: [VNBarcodeSymbology] = allSymbologies) throws -> [QRDetection] {
        try autoreleasepool { try scanWithVisionUnpooled(image, symbologies: symbologies) }
    }

    private func scanWithVisionUnpooled(_ image: CGImage, symbologies: [VNBarcodeSymbology]) throws -> [QRDetection] {
        var detections: [QRDetection] = []
        var scanError: Error?

        let request = VNDetectBarcodesRequest { request, error in
            if let error = error {
                scanError = error
                return
            }

            guard let results = request.results as? [VNBarcodeObservation] else { return }

            for obs in results {
                // An empty payload is noise, not a code: Vision reports one (as Micro QR) on some
                // heavily distorted QR texture once it is mutated.
                guard let payload = obs.payloadStringValue, !payload.isEmpty else { continue }

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

        request.symbologies = symbologies

        request.usesCPUOnly = false
        try applyComputePreference(to: request)

        // One context for the whole scan (a new one per request was a fresh GPU context and
        // its caches for every mutation).
        var options: [VNImageOption: Any] = [:]
        if metalDevice != nil {
            options[.ciContext] = ciContext
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
