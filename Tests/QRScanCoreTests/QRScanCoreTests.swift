import AppKit
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
