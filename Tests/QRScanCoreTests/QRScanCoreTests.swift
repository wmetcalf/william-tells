import AppKit
import CoreImage
import Foundation
import Vision
import ImageIO
import Testing
import zlib
@testable import QRScanCore

// Swift Testing (not XCTest): it ships with the Command Line Tools, so `swift test` works on a
// Mac without a full Xcode install -- the shape of most worker hosts.

@Suite struct MutationConfigTests {
    @Test func defaultsValidate() throws {
        _ = try MutationConfig.default.validated()
        _ = try MutationConfig.heavy.validated()
    }

    @Test func rejectsOutOfRangeAndNonFinite() {
        #expect(throws: (any Error).self) { try MutationConfig(scales: [0]).validated() }
        #expect(throws: (any Error).self) { try MutationConfig(blurRadii: [11]).validated() }
        #expect(throws: (any Error).self) { try MutationConfig(brightnessDeltas: [.nan]).validated() }
        #expect(throws: (any Error).self) {
            try MutationConfig(scales: Array(repeating: 1.0, count: 11)).validated()
        }
    }
}

@Suite struct ImageLoadingTests {
    @Test func garbageIsRefused() {
        #expect(throws: (any Error).self) {
            try QRScannerEngine.loadImage(from: Data(repeating: 0x41, count: 512))
        }
    }

    /// A ~60 KB PNG that decodes to 20000x20000 must be refused from the header alone --
    /// before ImageIO is asked to allocate 1.6 GB for it.
    @Test func decompressionBombRefusedBeforeDecode() throws {
        let bomb = try #require(pngBomb(width: 20000, height: 20000))
        do {
            _ = try QRScannerEngine.loadImage(from: bomb)
            Issue.record("expected imageTooLarge")
        } catch ScanError.imageTooLarge(let w, let h) {
            #expect(w == 20000 && h == 20000)
        } catch {
            Issue.record("expected imageTooLarge, got \(error)")
        }
    }

    @Test func unsupportedRasterTypeRefused() throws {
        // Valid image data in a type outside the allowlist (JPEG 2000).
        let img = CIImage(color: .red).cropped(to: CGRect(x: 0, y: 0, width: 8, height: 8))
        let cg = try #require(CIContext().createCGImage(img, from: img.extent))
        let data = NSMutableData()
        let dest = try #require(CGImageDestinationCreateWithData(data, "public.jpeg-2000" as CFString, 1, nil))
        CGImageDestinationAddImage(dest, cg, nil)
        #expect(CGImageDestinationFinalize(dest))
        do {
            _ = try QRScannerEngine.loadImage(from: data as Data)
            Issue.record("expected unsupportedType")
        } catch ScanError.unsupportedType {
        } catch {
            Issue.record("expected unsupportedType, got \(error)")
        }
    }
}

@Suite struct ScanTests {
    @Test func decodesGeneratedQR() async throws {
        let message = "https://example.com/\(UUID().uuidString)"
        let png = try #require(qrPNG(message))
        let report = try await QRScannerEngine().scan(imageData: png, config: .default, earlyExit: true)
        #expect(report.detections.map(\.payload) == [message])
        #expect(report.mutationsTried == 0)
    }

    @Test func noCodeMeansNoDetections() async throws {
        let img = CIImage(color: .white).cropped(to: CGRect(x: 0, y: 0, width: 64, height: 64))
        let cs = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let png = try #require(CIContext().pngRepresentation(of: img, format: .RGBA8, colorSpace: cs))
        let report = try await QRScannerEngine().scan(imageData: png, config: MutationConfig(
            scales: [1.0], brightnessDeltas: [0.0], contrastDeltas: [0.0], blurRadii: [0.0],
            rotationDegrees: [0.0], sharpenIntensities: [0.0]), earlyExit: true)
        #expect(report.detections.isEmpty)
    }
}

@Suite struct ScanBudgetTests {
    @Test func aPassedDeadlineStopsTheSweepAndSaysSo() async throws {
        let png = try #require(blankPNG(width: 64, height: 64))
        let report = try await QRScannerEngine().scan(imageData: png, config: .heavy, earlyExit: false,
                                                      deadline: Date())
        #expect(report.budgetExhausted && report.mutationsTried == 0 && report.detections.isEmpty)
    }

    @Test func withoutADeadlineTheSweepIsComplete() async throws {
        let png = try #require(blankPNG(width: 64, height: 64))
        let config = MutationConfig(scales: [1.0], brightnessDeltas: [0.0, 0.1], contrastDeltas: [0.0],
                                    blurRadii: [0.0], rotationDegrees: [0.0], sharpenIntensities: [0.0])
        let report = try await QRScannerEngine().scan(imageData: png, config: config, earlyExit: false)
        // The two mutations, after the perspective pass's stretches (a blank page has no
        // rectangles to unwarp).
        #expect(!report.budgetExhausted && report.mutationsTried == 2 + QRScannerEngine.stretches.count)
    }

    @Test func theBudgetLeavesHeadroomInsideTheTimeout() {
        #expect(ScanJob.budget(forTimeout: 120) == 96)
        #expect(ScanJob.budget(forTimeout: 20) == 15)
        #expect(ScanJob.budget(forTimeout: 1) == 1)
    }

    @Test func anOlderReportWithoutTheFlagDecodesAsComplete() throws {
        let json = #"{"imageDimensions":{"width":1,"height":1},"mutationsTried":0,"detections":[]}"#
        #expect(try JSONDecoder().decode(ScanReport.self, from: Data(json.utf8)).budgetExhausted == false)
    }
}

@Suite struct MutationOrderTests {
    @Test func heavyTriesTheDefaultMutationsFirst() {
        let order = QRScannerEngine.orderedMutations(.heavy, width: 500, height: 500)
        let defaults = QRScannerEngine.orderedMutations(.default, width: 500, height: 500)
        #expect(order.count == 6000 && defaults.count == 60)
        #expect(Array(order.prefix(defaults.count)) == defaults)
        #expect(Set(order).count == order.count)
    }

    @Test func largeImagesAreNotRenderedPastTheWorkingSize() {
        let (w, h) = (4032, 3024)
        let order = QRScannerEngine.orderedMutations(.heavy, width: w, height: h)
        let biggest = order.map { Double(w) * $0.scale * Double(h) * $0.scale }.max() ?? 0
        #expect(biggest <= Double(QRScannerEngine.maxWorkingPixels) * 1.0001)
        #expect(order.count < 6000 && Set(order).count == order.count)   // clamped scales merged
    }
}

@Suite struct TilingTests {
    @Test func smallImagesAreScannedWhole() {
        #expect(QRScannerEngine.tileRects(width: 1536, height: 900).isEmpty)
    }

    @Test func tilesCoverTheImageAndOverlap() {
        let (w, h) = (4032, 3024)
        let rects = QRScannerEngine.tileRects(width: w, height: h)
        #expect(rects.allSatisfy { $0.width == 1024 && $0.height == 1024 })
        #expect(rects.allSatisfy { $0.minX >= 0 && $0.minY >= 0 && $0.maxX <= CGFloat(w) && $0.maxY <= CGFloat(h) })
        // Every point is inside some tile (sampled on a grid, edges included).
        for x in stride(from: 0, through: w - 1, by: 97) {
            for y in stride(from: 0, through: h - 1, by: 97) {
                #expect(rects.contains { $0.contains(CGPoint(x: x, y: y)) })
            }
        }
        #expect(rects.contains { $0.maxX == CGFloat(w) } && rects.contains { $0.maxY == CGFloat(h) })
    }

    @Test func aTileDetectionMapsToTheWholeImage() throws {
        let cs = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let ctx = try #require(CGContext(data: nil, width: 2048, height: 2048, bitsPerComponent: 8,
                                         bytesPerRow: 0, space: cs,
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = try #require(ctx.makeImage())
        // Tile = top-right quarter; a box filling the tile's bottom-left quarter.
        let d = QRDetection(payload: "p", symbology: "qr", confidence: 1,
                            boundingBox: BoundingBox(x: 0, y: 0, width: 0.5, height: 0.5))
        let m = QRScannerEngine.toFullImage(d, tile: CGRect(x: 1024, y: 0, width: 1024, height: 1024), of: image)
        #expect(m.boundingBox.x == 0.5 && m.boundingBox.y == 0.5)
        #expect(m.boundingBox.width == 0.25 && m.boundingBox.height == 0.25)
    }

    @Test func theSamePayloadAtTwoPlacesIsTwoCodes() throws {
        func det(_ x: Double) -> QRDetection {
            QRDetection(payload: "same", symbology: "qr", confidence: 1,
                        boundingBox: BoundingBox(x: x, y: 0.1, width: 0.05, height: 0.05))
        }
        var set = QRScannerEngine.DetectionSet()
        try set.add([det(0.1), det(0.3)])
        try set.add([det(0.101)])              // the first one again, seen by an overlapping tile
        #expect(set.items.count == 2)
    }

    @Test func tilesComeBackInTileOrderWhateverTheWorkers() throws {
        let messages = (0..<8).map { "https://example.com/order/\($0)" }
        let png = try #require(gridPNG(messages, width: 3000, height: 2000, moduleScale: 3))
        let image = try QRScannerEngine.loadImage(from: png)
        let engine = QRScannerEngine()
        let serial = try engine.scanTiles(of: image, workers: 1, expired: { false })
        let parallel = try engine.scanTiles(of: image, workers: 4, expired: { false })
        #expect(serial.detections.map { $0.map(\.payload) } == parallel.detections.map { $0.map(\.payload) })
        #expect(!serial.expired && serial.detections.joined().count >= messages.count)
    }

    @Test func tilesStopAtTheDeadline() throws {
        let png = try #require(blankPNG(width: 3000, height: 2000))
        let tiles = try QRScannerEngine().scanTiles(of: try QRScannerEngine.loadImage(from: png), expired: { true })
        #expect(tiles.expired && tiles.detections.joined().isEmpty)
    }

    /// Many small codes on a large page: Vision reads few of them from the whole frame, the
    /// native-resolution tiles read them all.
    @Test func manySmallCodesOnALargeImageAreAllFound() async throws {
        let messages = (0..<12).map { "https://example.com/tile/\($0)" }
        let png = try #require(gridPNG(messages, width: 4000, height: 3000, moduleScale: 3))
        let report = try await QRScannerEngine().scan(imageData: png, config: .default, earlyExit: true)
        #expect(Set(report.detections.map(\.payload)) == Set(messages))
        #expect(report.detections.count == messages.count)
    }
}

@Suite struct MicroQRMisreadTests {
    static let micro = VNBarcodeSymbology.microQR.rawValue
    static let qr = VNBarcodeSymbology.qr.rawValue

    func det(_ payload: String, _ symbology: String, x: Double = 0.1, size: Double = 0.1) -> QRDetection {
        QRDetection(payload: payload, symbology: symbology, confidence: 1,
                    boundingBox: BoundingBox(x: x, y: 0.1, width: size, height: size))
    }

    @Test func aMicroQROnTheRawImageIsAcceptedAtOnce() throws {
        var set = QRScannerEngine.DetectionSet()
        let added = try set.add([det("347", Self.micro)])
        #expect(added && set.items.map(\.payload) == ["347"])
    }

    /// Read once in a mutated view and not confirmed close up, a Micro QR neither ends an
    /// early-exit scan nor is reported.
    @Test func anUnconfirmedMicroQRFromAMutatedViewIsNotReported() throws {
        var set = QRScannerEngine.DetectionSet()
        let added = try set.add([det("347", Self.micro)], mutated: true, confirm: { _ in false })
        #expect(!added && set.items.isEmpty)
    }

    @Test func aCloseReReadConfirmsItAtOnce() throws {
        var set = QRScannerEngine.DetectionSet()
        var asked: [Int] = []
        let added = try set.add([det("real", Self.micro), det("junk", Self.micro, x: 0.6)], mutated: true,
                                confirm: { asked.append($0); return $0 == 0 })
        #expect(added && asked == [0, 1] && set.items.map(\.payload) == ["real"])
    }

    @Test func aSecondViewConfirmsIt() throws {
        var set = QRScannerEngine.DetectionSet()
        try set.add([det("347", Self.micro)], mutated: true)
        let added = try set.add([det("347", Self.micro, x: 0.102)], mutated: true)
        #expect(added && set.items.map(\.payload) == ["347"])
    }

    /// Vision can return one read twice, and every read in an unwarped rectangle carries the
    /// rectangle's box: neither is a second view.
    @Test func aViewCannotConfirmItsOwnRead() throws {
        var set = QRScannerEngine.DetectionSet()
        try set.add([det("347", Self.micro), det("347", Self.micro)], mutated: true, exactBoxes: false)
        #expect(set.items.isEmpty)
    }

    @Test func aMicroQRLyingOnADecodedQRIsDropped() throws {
        var set = QRScannerEngine.DetectionSet()
        try set.add([det("https://example.com", Self.qr, x: 0.1, size: 0.5), det("2Z", Self.micro, x: 0.2)])
        try set.add([det("elsewhere", Self.micro, x: 0.8)])
        #expect(set.items.map(\.payload) == ["https://example.com", "elsewhere"])
    }

    /// An unwarped rectangle's box (a whole sheet, maybe most of the frame) is not the QR's own,
    /// so it doesn't hide Micro QRs.
    @Test func anApproximateQRBoxDropsNothing() throws {
        var set = QRScannerEngine.DetectionSet()
        try set.add([det("https://example.com", Self.qr, x: 0, size: 1)], mutated: true, exactBoxes: false)
        try set.add([det("2Z", Self.micro, x: 0.2)])
        #expect(set.items.map(\.payload) == ["https://example.com", "2Z"])
    }

    @Test func otherSymbologiesFromMutatedViewsAreAcceptedAtOnce() throws {
        var set = QRScannerEngine.DetectionSet()
        let added = try set.add([det("https://example.com", Self.qr)], mutated: true)
        #expect(added && set.items.count == 1)
    }
}

@Suite struct MutatedFrameTests {
    func box(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> QRDetection {
        QRDetection(payload: "p", symbology: "qr", confidence: 1, boundingBox: BoundingBox(x: x, y: y, width: w, height: h))
    }

    func close(_ a: BoundingBox, _ b: BoundingBox) -> Bool {
        abs(a.x - b.x) < 1e-9 && abs(a.y - b.y) < 1e-9 && abs(a.width - b.width) < 1e-9 && abs(a.height - b.height) < 1e-9
    }

    @Test func aScaledFrameHasTheImagesCoordinates() {
        let d = box(0.1, 0.2, 0.3, 0.4)
        let m = QRScannerEngine.toImage(d, scale: 2, rotation: 0, frame: CGRect(x: 0, y: 0, width: 200, height: 100),
                                        width: 100, height: 50)
        #expect(close(m.boundingBox, d.boundingBox))
    }

    /// Rotating 100x50 by 90 degrees gives a frame at x -50...0: a box at pixels x 10-20,
    /// y 5-15 lands at x -15...-5, y 10-20 there.
    @Test func aRotatedFramesBoxMapsBack() {
        let d = box(0.7, 0.1, 0.2, 0.1)
        let m = QRScannerEngine.toImage(d, scale: 1, rotation: 90, frame: CGRect(x: -50, y: 0, width: 50, height: 100),
                                        width: 100, height: 50)
        #expect(close(m.boundingBox, BoundingBox(x: 0.1, y: 0.1, width: 0.1, height: 0.2)))
    }
}

@Suite struct PerspectiveTests {
    /// A code squashed to a third of its width (a steep viewing angle): the raw pass misses it,
    /// the perspective pass reads it before any brightness/contrast mutation.
    @Test func aForeshortenedCodeIsReadByStretchingItBack() async throws {
        let message = "https://example.com/\(UUID().uuidString)"
        let png = try #require(qrPNG(message, scaleX: 10.0 / 3, scaleY: 10))
        let raw = try await QRScannerEngine().scan(imageData: png, config: MutationConfig(
            scales: [1.0], brightnessDeltas: [0.0], contrastDeltas: [0.0], blurRadii: [0.0],
            rotationDegrees: [0.0], sharpenIntensities: [0.0]), earlyExit: true, deadline: nil)
        #expect(raw.detections.map(\.payload) == [message])
        #expect(raw.mutationsTried >= 1 && raw.mutationsTried <= QRScannerEngine.stretches.count)
    }
}

// MARK: - helpers

private func qrPNG(_ message: String, scaleX: CGFloat = 10, scaleY: CGFloat = 10) -> Data? {
    let gen = CIFilter(name: "CIQRCodeGenerator")
    gen?.setValue(Data(message.utf8), forKey: "inputMessage")
    guard let qr = gen?.outputImage?.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY)) else { return nil }
    let canvas = CIImage(color: .white).cropped(to: qr.extent.insetBy(dx: -40, dy: -40))
    guard let cs = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
    return CIContext().pngRepresentation(of: qr.composited(over: canvas), format: .RGBA8, colorSpace: cs)
}

private func blankPNG(width: Int, height: Int) -> Data? {
    let img = CIImage(color: .white).cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
    guard let cs = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
    return CIContext().pngRepresentation(of: img, format: .RGBA8, colorSpace: cs)
}

/// `messages` as small QRs spread over a white `width` x `height` page.
private func gridPNG(_ messages: [String], width: Int, height: Int, moduleScale: CGFloat) -> Data? {
    var page = CIImage(color: .white).cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
    let cols = 4
    for (i, m) in messages.enumerated() {
        let gen = CIFilter(name: "CIQRCodeGenerator")
        gen?.setValue(Data(m.utf8), forKey: "inputMessage")
        guard let qr = gen?.outputImage?.transformed(by: CGAffineTransform(scaleX: moduleScale, y: moduleScale))
        else { return nil }
        let x = CGFloat(i % cols) * CGFloat(width) / CGFloat(cols) + 200
        let y = CGFloat(i / cols) * CGFloat(height) / CGFloat((messages.count + cols - 1) / cols) + 200
        page = qr.transformed(by: CGAffineTransform(translationX: x, y: y)).composited(over: page)
    }
    guard let cs = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
    return CIContext().pngRepresentation(of: page, format: .RGBA8, colorSpace: cs)
}

/// A complete, valid 1-bit grayscale PNG of all-zero pixels. ImageIO refuses a header-only PNG
/// as invalid data, so the bomb has to be real; the zeros deflate to almost nothing.
private func pngBomb(width: UInt32, height: UInt32) -> Data? {
    let rowBytes = 1 + (Int(width) + 7) / 8                     // filter byte + packed pixels
    let raw = Data(count: rowBytes * Int(height))
    var destLen = compressBound(uLong(raw.count))
    var idat = Data(count: Int(destLen))
    let rc = idat.withUnsafeMutableBytes { dst in
        raw.withUnsafeBytes { src in
            compress2(dst.bindMemory(to: Bytef.self).baseAddress, &destLen,
                      src.bindMemory(to: Bytef.self).baseAddress, uLong(raw.count), 9)
        }
    }
    guard rc == Z_OK else { return nil }
    idat.count = Int(destLen)

    var ihdr = Data()
    for v in [width, height] { withUnsafeBytes(of: v.bigEndian) { ihdr.append(contentsOf: $0) } }
    ihdr.append(contentsOf: [1, 0, 0, 0, 0])   // 1-bit grayscale, deflate, no filter, no interlace

    var d = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
    for (type, body) in [("IHDR", ihdr), ("IDAT", idat), ("IEND", Data())] {
        let chunk = Data(type.utf8) + body
        withUnsafeBytes(of: UInt32(body.count).bigEndian) { d.append(contentsOf: $0) }
        d.append(chunk)
        let crc = chunk.withUnsafeBytes {
            UInt32(crc32(0, $0.bindMemory(to: Bytef.self).baseAddress, uInt(chunk.count)))
        }
        withUnsafeBytes(of: crc.bigEndian) { d.append(contentsOf: $0) }
    }
    return d
}

@Suite struct SVGDetectionTests {
    static let ns = "http://www.w3.org/2000/svg"
    static let wh = " width='10' height='10'"
    static func u(_ s: String) -> Data { Data(s.utf8) }

    /// SVG documents NSImage renders: each must be routed to the SVG path.
    static let svg: [(String, Data)] = [
        ("plain", u("<svg xmlns=\"\(ns)\"\(wh)/>")),
        ("prolog", u("\u{FEFF}<?xml version=\"1.0\"?>\n<!-- hi -->\n<!DOCTYPE svg PUBLIC \"-//W3C//DTD SVG 1.1//EN\" \"x\">\n<svg\(wh)/>")),
        ("whitespace", u("\n\t<svg\(wh)/>")),
        ("subset", u("<!DOCTYPE svg [<!ENTITY x \"v>\"><!ELEMENT svg ANY>]><svg\(wh)/>")),
        ("subset comment", u("<!DOCTYPE svg [<!-- ] --><!ELEMENT svg ANY>]><svg\(wh)/>")),
        ("subset PI", u("<!DOCTYPE svg [<?pi ]> ?><!ELEMENT svg ANY>]><svg\(wh)/>")),
        ("prefixed", u("<svg:svg xmlns:svg=\"\(ns)\"\(wh)/>")),
        ("char refs", u("<s:svg xmlns:s=\"http:&#x2F;&#x2F;www.w3.org/2000/svg\"\(wh)/>")),
        ("entity", u("<!DOCTYPE s:svg [<!ENTITY n \"\(ns)\">]><s:svg xmlns:s=\"&n;\"\(wh)/>")),
        ("long prolog", u("<!-- " + String(repeating: "x", count: 10_000) + " --><svg\(wh)/>")),
        ("UTF-16LE BOM", Data([0xFF, 0xFE]) + "<svg\(wh)/>".data(using: .utf16LittleEndian)!),
        ("UTF-16BE BOM", Data([0xFE, 0xFF]) + "<svg\(wh)/>".data(using: .utf16BigEndian)!),
        ("UTF-16 decl", "<?xml version='1.0' encoding='UTF-16'?><svg\(wh)/>".data(using: .utf16LittleEndian)!),
        ("UTF-32BE", "<svg\(wh)/>".data(using: .utf32BigEndian)!),
    ]

    /// Not SVG: other formats mentioning "<svg", other roots/namespaces, and XML NSImage
    /// can't read either (so routing it to ImageIO's "unsupported type" loses nothing).
    static let notSVG: [(String, Data)] = [
        ("PNG text chunk", Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) + u("\0\0\0\u{10}tEXtComment\0<svg>")),
        ("PSD", u("8BPS\0\u{1}<svg xmlns=\"x\">")),
        ("html root", u("<?xml version=\"1.0\"?><html><svg\(wh)/></html>")),
        ("svgfoo", u("<svgfoo/>")),
        ("unbound prefix", u("<svg:svg\(wh)/>")),
        ("other namespace", u("<x:svg xmlns:x=\"urn:not-svg\"\(wh)/>")),
        ("default other namespace", u("<svg xmlns=\"urn:not-svg\"\(wh)/>")),
        ("wrong prefix", u("<x:svg xmlns:y=\"\(ns)\"\(wh)/>")),
        ("unterminated subset", u("<!DOCTYPE svg [<!-- ]><svg/>")),
        ("UTF-16 no BOM", "<svg\(wh)/>".data(using: .utf16LittleEndian)!),
        ("UTF-32LE", "<svg\(wh)/>".data(using: .utf32LittleEndian)!),
        ("entity bomb", u("<!DOCTYPE s [<!ENTITY a \"aaaaaaaaaa\">" + (1...9).map { n in
            "<!ENTITY \(Character(UnicodeScalar(97 + n)!)) \"" + String(repeating: "&\(Character(UnicodeScalar(96 + n)!));", count: 10) + "\">"
        }.joined() + "]><svg xmlns='\(ns)' a='&j;'/>")),
        ("external entity", u("<!DOCTYPE svg [<!ENTITY x SYSTEM \"file:///etc/passwd\">]><x>&x;</x>")),
        ("empty", Data()), ("one byte", Data([0xFF])), ("BOM only", Data([0xFF, 0xFE])),
    ]

    @Test func svgDocumentsAreSVG() {
        for (name, d) in Self.svg { #expect(QRScannerEngine.isSVG(d), "\(name)") }
    }

    @Test func otherInputsAreNotSVG() {
        for (name, d) in Self.notSVG { #expect(!QRScannerEngine.isSVG(d), "\(name)") }
    }

    @Test func everyDocumentRoutedToSVGIsOneNSImageRenders() {
        // isSVG and NSImage both read XML with libxml2: what we route there, it can draw.
        for (name, d) in Self.svg { #expect(NSImage(data: d) != nil, "\(name)") }
    }

    /// A HEIC from ImageIO, and the same file re-branded as generic HEIF (`mif1`): ImageIO
    /// can't write generic HEIF itself but reads this as `public.heif`.
    static func heicAndHEIF() -> (heic: Data, heif: Data) {
        let ctx = CGContext(data: nil, width: 16, height: 16, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let out = NSMutableData()
        let dst = CGImageDestinationCreateWithData(out, "public.heic" as CFString, 1, nil)!
        CGImageDestinationAddImage(dst, ctx.makeImage()!, nil)
        _ = CGImageDestinationFinalize(dst)
        let heic = out as Data
        var heif = heic
        let ftypEnd = Int(heif[0]) << 24 | Int(heif[1]) << 16 | Int(heif[2]) << 8 | Int(heif[3])
        for i in stride(from: 8, to: ftypEnd - 3, by: 4) where heif[i..<i + 4] == Data("heic".utf8) {
            heif.replaceSubrange(i..<i + 4, with: Data("mif1".utf8))
        }
        return (heic, heif)
    }

    @Test func genericHEIFIsLabelledHEIFNotHEIC() {
        let (heic, heif) = Self.heicAndHEIF()
        #expect(QRScannerEngine.inputType(heic) == "heic")
        #expect(QRScannerEngine.inputType(heif) == "heif")
        #expect(QRScannerEngine.inputMIMEs["heif"] == "image/heif")
        #expect(QRScannerEngine.inputMIMEs["heic"] == "image/heic")
    }

    @Test func inputTypeLabelsWhatTheScannerAccepts() {
        for (name, d) in Self.svg { #expect(QRScannerEngine.inputType(d) == "svg", "\(name)") }
        #expect(QRScannerEngine.inputType(Self.notSVG[0].1) == "png")  // "<svg" in a PNG: still a PNG
        #expect(QRScannerEngine.inputType(Data("%PDF-1.7\n".utf8)) == "pdf")
        #expect(QRScannerEngine.inputType(Self.u("<html/>")) == nil)
        for label in ["svg", "pdf", "png", "jpeg"] { #expect(QRScannerEngine.inputMIMEs[label] != nil) }
    }
}
