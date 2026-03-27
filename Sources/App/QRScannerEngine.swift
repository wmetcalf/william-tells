import Foundation
import Vision
import AppKit
import CoreImage
import Metal

// MARK: - QR Scanner Engine

actor QRScannerEngine {

    private let ciContext: CIContext
    private let metalDevice: MTLDevice?

    init() {
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

    func scan(imageData: Data, config: MutationConfig, earlyExit: Bool = false) async throws -> ScanReport {
        guard let cgImage = Self.loadImage(from: imageData) else {
            throw ScanError.invalidImageData
        }

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

        var options: [VNImageOption: Any] = [:]
        if let device = metalDevice {
            options[.ciContext] = CIContext(mtlDevice: device)
        }
        let handler = VNImageRequestHandler(cgImage: image, options: options)
        try handler.perform([request])

        if let error = scanError { throw error }

        return detections
    }

    // MARK: - Image Loading (PNG, JPEG, HEIC, HEIF, TIFF, GIF, BMP, WebP, SVG, PDF)

    private static let vectorRasterSize: CGFloat = 2048

    private static func loadImage(from data: Data) -> CGImage? {
        if isSVG(data) { return rasterizeSVG(data) }
        if isPDF(data) { return rasterizePDF(data) }

        guard let nsImage = NSImage(data: data),
              let cgImage = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { return nil }
        return cgImage
    }

    private static func isSVG(_ data: Data) -> Bool {
        let prefix = data.prefix(1024)
        guard let str = String(data: prefix, encoding: .utf8)?.lowercased() else { return false }
        return str.contains("<svg") || (str.contains("<?xml") && str.contains("svg"))
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

enum ScanError: Error, LocalizedError {
    case invalidImageData

    var errorDescription: String? {
        switch self {
        case .invalidImageData:
            return "Could not decode image data. Supported formats: PNG, JPEG, HEIC, SVG, PDF, WebP, TIFF, GIF, BMP."
        }
    }
}
