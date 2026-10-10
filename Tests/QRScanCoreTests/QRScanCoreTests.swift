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

    /// A PNG whose IHDR claims 20000x20000 must be refused from the header alone --
    /// before ImageIO is asked to allocate 1.6 GB for it.
    @Test func decompressionBombRefusedBeforeDecode() {
        do {
            _ = try QRScannerEngine.loadImage(from: pngHeader(width: 20000, height: 20000))
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

/// PNG signature + a valid IHDR chunk (correct CRC) and nothing else.
private func pngHeader(width: UInt32, height: UInt32) -> Data {
    var d = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
    var body = Data("IHDR".utf8)
    for v in [width, height] { withUnsafeBytes(of: v.bigEndian) { body.append(contentsOf: $0) } }
    body.append(contentsOf: [8, 6, 0, 0, 0])   // 8-bit RGBA, deflate, no filter, no interlace
    withUnsafeBytes(of: UInt32(13).bigEndian) { d.append(contentsOf: $0) }
    d.append(body)
    let crc = body.withUnsafeBytes { UInt32(crc32(0, $0.bindMemory(to: UInt8.self).baseAddress, uInt(body.count))) }
    withUnsafeBytes(of: crc.bigEndian) { d.append(contentsOf: $0) }
    return d
}
