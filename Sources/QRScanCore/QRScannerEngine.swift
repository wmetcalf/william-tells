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
    /// Largest `mutationsTried` a scan can report: a maximal config plus every perspective view.
    /// Hosts validating scanner output bound it by this (the Python engine mirrors the value).
    public static let maxMutationsTried = MutationConfig.maxTotalMutations + stretches.count + maxRectangles
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
    ///
    /// Vision misreads QR texture as a Micro QR once a damaged or noisy QR is mutated (short
    /// junk payloads like "347" or "2Z": Micro QR has little or no error correction, M1 only
    /// detects errors). So a Micro QR first seen in a mutated view is tentative: it is accepted
    /// when a second view reads it too, or when `confirm` reads it again from a close crop of
    /// the view it was seen in; and a Micro QR lying on a decoded QR is dropped.
    struct DetectionSet {
        private var accepted: [QRDetection] = []
        private var tentative: [(detection: QRDetection, evidence: CGImage?)] = []
        /// Most tentative detections holding evidence at once.
        static let maxEvidence = 16

        /// Adds detections; true when any is new and accepted. `mutated`: they come from a
        /// mutated or unwarped view, not the raw image. `evidence(i)`: a close crop of the view
        /// around `dets[i]`, kept for `confirm` if that detection is tentative.
        @discardableResult
        mutating func add(_ dets: [QRDetection], mutated: Bool = false,
                          evidence: (Int) -> CGImage? = { _ in nil }) -> Bool {
            var foundNew = false
            for (i, d) in dets.enumerated() where !accepted.contains(where: { Self.same($0, d) }) {
                if mutated && Self.isMicroQR(d) {
                    if let j = tentative.firstIndex(where: { Self.same($0.detection, d) }) {
                        tentative.remove(at: j)
                    } else {
                        // Evidence is up to 4 MB; a long sweep over noisy texture can misread
                        // hundreds of distinct payloads, so only the first few keep theirs.
                        let keep = tentative.lazy.filter { $0.evidence != nil }.count < Self.maxEvidence
                        tentative.append((d, keep ? evidence(i) : nil))
                        continue
                    }
                }
                accepted.append(d)
                foundNew = true
            }
            return foundNew
        }

        /// Settles the tentative detections: accepts those `reads` reads again from their
        /// evidence, drops the rest.
        mutating func confirm(_ reads: (QRDetection, CGImage) throws -> Bool) rethrows {
            for (d, evidence) in tentative {
                if let evidence, !accepted.contains(where: { Self.same($0, d) }), try reads(d, evidence) {
                    accepted.append(d)
                }
            }
            tentative = []
        }

        /// The detections to report.
        var items: [QRDetection] {
            let qrs = accepted.filter { !Self.isMicroQR($0) && $0.symbology == VNBarcodeSymbology.qr.rawValue }
            return accepted.filter { d in !(Self.isMicroQR(d) && qrs.contains { Self.centerInside(d, $0) }) }
        }

        static func isMicroQR(_ d: QRDetection) -> Bool { d.symbology == VNBarcodeSymbology.microQR.rawValue }

        static func centerInside(_ d: QRDetection, _ box: QRDetection) -> Bool {
            let (c, b) = (d.boundingBox, box.boundingBox)
            let (cx, cy) = (c.x + c.width / 2, c.y + c.height / 2)
            return cx >= b.x && cx <= b.x + b.width && cy >= b.y && cy <= b.y + b.height
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
        let tiles = try scanTiles(of: image, expired: expired)
        for dets in tiles.detections { found.add(dets) }
        if tiles.expired { return (found.items, 0, true) }
        if !found.items.isEmpty {
            return (found.items, 0, false)
        }

        // 2. Nothing found on the raw image: undo a steep viewing angle (stretches, then unwarped
        // rectangles), then the brightness/contrast/... mutations — until the deadline. Every
        // view counts as a mutation tried.
        var mutationsTried = 0
        // Every exit from here settles the tentative Micro QR reads first (unless out of time).
        func finish(_ exhausted: Bool) throws -> (detections: [QRDetection], mutationsTried: Int, budgetExhausted: Bool) {
            if !exhausted {
                try found.confirm { d, evidence in try confirms(d, in: evidence, expired: expired) }
            }
            return (found.items, mutationsTried, exhausted || expired())
        }
        for view in perspectiveViews(of: image) {
            if expired() { return try finish(true) }
            mutationsTried += 1
            let foundNew = try autoreleasepool { () -> Bool in
                guard let (rendered, box) = view() else { return false }
                // Boxes in a stretched view are already in the image's normalized coordinates;
                // in an unwarped rectangle they are reported as that rectangle's bounds.
                let dets = try scanWithVision(rendered)
                return found.add(dets.map { d in
                    box.map { QRDetection(payload: d.payload, symbology: d.symbology,
                                          confidence: d.confidence, boundingBox: $0) } ?? d
                }, mutated: true, evidence: { evidenceCrop(of: rendered, around: dets[$0]) })
            }
            if earlyExit && foundNew { return try finish(false) }
        }
        for m in Self.orderedMutations(config, width: image.width, height: image.height) {
            if expired() { return try finish(true) }
            mutationsTried += 1
            // Each mutation renders a full frame and Vision allocates per request; without a
            // pool per iteration those autoreleased buffers pile up until the sweep ends
            // (gigabytes on a large photo).
            let foundNew = try autoreleasepool { () -> Bool in
                guard let mutated = applyMutation(to: image,
                    scale: m.scale, brightness: m.brightness, contrast: m.contrast,
                    blur: m.blur, rotation: m.rotation, sharpen: m.sharpen
                ) else { return false }
                let dets = try scanWithVision(mutated)
                return found.add(dets, mutated: true,
                                 evidence: { evidenceCrop(of: mutated, around: dets[$0]) })
            }
            if earlyExit && foundNew { return try finish(false) }
        }

        return try finish(false)
    }

    /// A copy (not a view sharing the frame's buffer) of the region around a detection: its box
    /// grown by half its size on every side, at most 1024 px on the long side.
    private nonisolated func evidenceCrop(of view: CGImage, around d: QRDetection) -> CGImage? {
        let (w, h) = (Double(view.width), Double(view.height))
        let b = d.boundingBox
        let r = CGRect(x: (b.x - b.width / 2) * w, y: (b.y - b.height / 2) * h,
                       width: b.width * 2 * w, height: b.height * 2 * h)
            .intersection(CGRect(x: 0, y: 0, width: w, height: h)).integral
        guard r.width >= 1, r.height >= 1 else { return nil }
        let k = min(1, 1024 / max(r.width, r.height))
        let crop = CIImage(cgImage: view).cropped(to: r)
            .transformed(by: CGAffineTransform(translationX: -r.minX, y: -r.minY))
            .transformed(by: CGAffineTransform(scaleX: k, y: k))
        return autoreleasepool { ciContext.createCGImage(crop, from: crop.extent) }
    }

    /// Views a tentative Micro QR's evidence is re-read in: (scale, blur radius). Blurring the
    /// enlarged crop smooths sensor noise out of the small modules.
    static let confirmViews: [(scale: Double, blur: Double)] = [(1, 0), (2, 0), (3, 0), (2, 1), (3, 2)]

    /// Whether Vision reads the tentative Micro QR `d` again from its evidence, close up.
    private nonisolated func confirms(_ d: QRDetection, in evidence: CGImage,
                                      expired: () -> Bool) throws -> Bool {
        for v in Self.confirmViews {
            if expired() { return false }
            let read = try autoreleasepool { () -> Bool in
                var img = CIImage(cgImage: evidence).transformed(by: CGAffineTransform(scaleX: v.scale, y: v.scale))
                if v.blur > 0 {
                    let extent = img.extent
                    img = img.clampedToExtent()
                        .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: v.blur])
                        .cropped(to: extent)
                }
                guard let cg = ciContext.createCGImage(img, from: img.extent) else { return false }
                return try scanWithVision(cg, symbologies: [.microQR]).contains { $0.payload == d.payload }
            }
            if read { return true }
        }
        return false
    }

    /// Most tiles scanned at once. Two cut a 12 MP photo's scan by about a fifth (0.26 s to
    /// 0.21 s); more don't help, as Vision largely serializes the requests.
    static let tileConcurrency = 2

    /// Scans the raw image's tiles, several at a time. Detections come back in tile order (so
    /// a scan's result doesn't depend on scheduling), mapped to whole-image coordinates.
    /// `expired`: the deadline passed before every tile was scanned.
    private nonisolated func scanTiles(of image: CGImage, expired: () -> Bool) throws
        -> (detections: [[QRDetection]], expired: Bool) {
        let rects = Self.tileRects(width: image.width, height: image.height)
        guard !rects.isEmpty else { return ([], false) }
        let lock = NSLock()
        var results = [[QRDetection]](repeating: [], count: rects.count)
        var firstError: Error?
        var skipped = false
        let workers = min(Self.tileConcurrency, rects.count)
        DispatchQueue.concurrentPerform(iterations: workers) { worker in
            for i in stride(from: worker, to: rects.count, by: workers) {
                lock.lock(); let stop = firstError != nil || skipped; lock.unlock()
                if stop { return }
                if expired() { lock.lock(); skipped = true; lock.unlock(); return }
                guard let tile = image.cropping(to: rects[i]) else { continue }
                do {
                    let dets = try scanWithVision(tile, symbologies: Self.tileSymbologies)
                        .map { Self.toFullImage($0, tile: rects[i], of: image) }
                    lock.lock(); results[i] = dets; lock.unlock()
                } catch {
                    lock.lock(); if firstError == nil { firstError = error }; lock.unlock()
                    return
                }
            }
        }
        if let firstError { throw firstError }
        return (results, skipped)
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

    private nonisolated func scanWithVision(_ image: CGImage,
                                symbologies: [VNBarcodeSymbology] = allSymbologies) throws -> [QRDetection] {
        try autoreleasepool { try scanWithVisionUnpooled(image, symbologies: symbologies) }
    }

    private nonisolated func scanWithVisionUnpooled(_ image: CGImage, symbologies: [VNBarcodeSymbology]) throws -> [QRDetection] {
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

    private nonisolated func applyComputePreference(to request: VNDetectBarcodesRequest) throws {
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
