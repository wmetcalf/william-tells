import CoreImage
import Foundation
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

// MARK: - helpers

private func qrPNG(_ message: String) -> Data? {
    let gen = CIFilter(name: "CIQRCodeGenerator")
    gen?.setValue(Data(message.utf8), forKey: "inputMessage")
    guard let qr = gen?.outputImage?.transformed(by: CGAffineTransform(scaleX: 10, y: 10)) else { return nil }
    let canvas = CIImage(color: .white).cropped(to: qr.extent.insetBy(dx: -40, dy: -40))
    guard let cs = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
    return CIContext().pngRepresentation(of: qr.composited(over: canvas), format: .RGBA8, colorSpace: cs)
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
    @Test func realSVGDocumentsAreSVG() {
        for doc in ["<svg xmlns=\"http://www.w3.org/2000/svg\"/>",
                    "\u{FEFF}  <?xml version=\"1.0\"?>\n<!-- hi -->\n<!DOCTYPE svg PUBLIC \"-//W3C//DTD SVG 1.1//EN\" \"x\">\n<svg width=\"1\">",
                    "\n\t<svg>",
                    // an internal subset: its declarations have their own '>'
                    "<!DOCTYPE svg [<!ENTITY x \"v>\"><!ELEMENT svg ANY>]><svg>",
                    "<!DOCTYPE svg PUBLIC \"a>b\" 'c>d'>\n<svg/>"] {
            #expect(QRScannerEngine.isSVG(Data(doc.utf8)), "\(doc)")
        }
    }

    @Test func otherFormatsMentioningSVGAreNot() {
        // "<svg" inside a PNG text chunk, a PSD resource, or an XML document whose root isn't svg
        var png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        png.append(Data("\0\0\0\u{10}tEXtComment\0<svg>".utf8))
        let psd = Data("8BPS\0\u{1}<svg xmlns=\"x\">".utf8)
        let xml = Data("<?xml version=\"1.0\"?><html><svg/></html>".utf8)
        let svgish = Data("<svgfoo/>".utf8)
        for d in [png, psd, xml, svgish] { #expect(!QRScannerEngine.isSVG(d)) }
    }

    @Test func shortMalformedUTF8IsNotSVGAndDoesNotTrap() {
        // fewer than three bytes that aren't UTF-8: the "cut mid-char" retry must not go negative
        for d in [Data([0xFF]), Data([0xFF, 0xFE]), Data([0xC3]), Data()] {
            #expect(!QRScannerEngine.isSVG(d))
        }
        #expect(!QRScannerEngine.isSVG(Data("<!DOCTYPE svg [<!ENTITY x \"v\">".utf8)))  // unterminated
    }

    @Test func aLongPrologStillFindsTheRoot() {
        // the root can sit well past the first 4 KiB: a long comment, then a long DOCTYPE subset
        let comment = "<!-- " + String(repeating: "x", count: 10_000) + " -->"
        let entities = (0..<300).map { "<!ENTITY e\($0) \"\($0)\">" }.joined()
        let doc = "<?xml version=\"1.0\"?>\(comment)<!DOCTYPE svg [\(entities)]>\n<svg width=\"1\"/>"
        #expect(Data(doc.utf8).count > 3 * 4096)
        #expect(QRScannerEngine.isSVG(Data(doc.utf8)))
        // non-ASCII inside a comment is fine; the scan never decodes UTF-8
        #expect(QRScannerEngine.isSVG(Data("<!-- café ☕ --><svg/>".utf8)))
    }

    @Test func utf16SVGIsSVG() {
        let doc = "<?xml version=\"1.0\" encoding=\"UTF-16\"?>\n<svg width=\"1\"/>"
        for enc in [String.Encoding.utf16LittleEndian, .utf16BigEndian] {
            let bare = doc.data(using: enc)!
            #expect(QRScannerEngine.isSVG(bare))                                   // no BOM
            let bom: [UInt8] = enc == .utf16LittleEndian ? [0xFF, 0xFE] : [0xFE, 0xFF]
            #expect(QRScannerEngine.isSVG(Data(bom) + bare))                        // with BOM
        }
        // UTF-16 whose root isn't svg, and odd-length / unpaired-surrogate UTF-16, are not SVG
        #expect(!QRScannerEngine.isSVG("<html><svg/></html>".data(using: .utf16LittleEndian)!))
        #expect(!QRScannerEngine.isSVG(Data([0xFF, 0xFE, 0x3C, 0x00, 0x73])))
        #expect(!QRScannerEngine.isSVG(Data([0xFF, 0xFE, 0x00, 0xD8, 0x3C, 0x00])))
    }

    @Test func bracketsInsideDoctypeCommentsAndPIsAreSkipped() {
        for doc in ["<!DOCTYPE svg [<!-- ] --><!ELEMENT svg ANY>]><svg/>",
                    "<!DOCTYPE svg [<!-- > ]> --><!ENTITY x \"v\">]>\n<svg/>",
                    "<!DOCTYPE svg [<?pi ]> ?><!ELEMENT svg ANY>]><svg/>"] {
            #expect(QRScannerEngine.isSVG(Data(doc.utf8)), "\(doc)")
        }
        #expect(!QRScannerEngine.isSVG(Data("<!DOCTYPE svg [<!-- ]><svg/>".utf8)))  // unterminated
    }
}
