import UIKit
import CoreImage
import Vision

// MARK: - Scanner Service

class ScannerService {
    static let shared = ScannerService()
    private init() {}

    private let ciContext = CIContext()

    // MARK: - Auto detect document corners

    func detectDocumentBounds(in image: UIImage) async -> [CGPoint]? {
        guard let cg = image.cgImage else { return nil }
        return await withCheckedContinuation { cont in
            let req = VNDetectRectanglesRequest { r, _ in
                guard let obs = (r.results as? [VNRectangleObservation])?.first else {
                    cont.resume(returning: nil); return
                }
                let w = CGFloat(cg.width), h = CGFloat(cg.height)
                cont.resume(returning: [
                    CGPoint(x: obs.topLeft.x * w,     y: (1 - obs.topLeft.y) * h),
                    CGPoint(x: obs.topRight.x * w,    y: (1 - obs.topRight.y) * h),
                    CGPoint(x: obs.bottomRight.x * w, y: (1 - obs.bottomRight.y) * h),
                    CGPoint(x: obs.bottomLeft.x * w,  y: (1 - obs.bottomLeft.y) * h),
                ])
            }
            req.minimumAspectRatio = 0.3
            req.maximumAspectRatio = 1.0
            req.minimumConfidence = 0.6
            req.maximumObservations = 1
            try? VNImageRequestHandler(cgImage: cg, options: [:]).perform([req])
        }
    }

    // MARK: - Perspective correction

    func applyPerspectiveCorrection(to image: UIImage, corners: [CGPoint]) -> UIImage {
        guard corners.count == 4, let ci = CIImage(image: image) else { return image }
        let h = ci.extent.height
        let tl = CIVector(x: corners[0].x, y: h - corners[0].y)
        let tr = CIVector(x: corners[1].x, y: h - corners[1].y)
        let br = CIVector(x: corners[2].x, y: h - corners[2].y)
        let bl = CIVector(x: corners[3].x, y: h - corners[3].y)
        guard let f = CIFilter(name: "CIPerspectiveCorrection") else { return image }
        f.setValue(ci, forKey: kCIInputImageKey)
        f.setValue(tl, forKey: "inputTopLeft")
        f.setValue(tr, forKey: "inputTopRight")
        f.setValue(br, forKey: "inputBottomRight")
        f.setValue(bl, forKey: "inputBottomLeft")
        guard let out = f.outputImage,
              let cg = ciContext.createCGImage(out, from: out.extent) else { return image }
        return UIImage(cgImage: cg)
    }

    // MARK: - Document enhancement (deblur & sharpen)

    /// Full pipeline for blurry/low-quality scans — runs before filters, translation, and stamping.
    func enhanceDocument(_ image: UIImage, strength: Double = 0.65) -> UIImage {
        guard var ci = CIImage(image: image) else { return image }
        let s = max(0.2, min(1.0, strength))
        let blurScore = estimateBlurScore(image)

        // Upscale low-resolution or blurry captures
        let maxDim = max(ci.extent.width, ci.extent.height)
        let upscaleTarget: CGFloat = blurScore < 120 ? 2000 : 1600
        if maxDim < upscaleTarget {
            let scale = upscaleTarget / maxDim
            if let f = CIFilter(name: "CILanczosScaleTransform") {
                f.setValue(ci, forKey: kCIInputImageKey)
                f.setValue(scale, forKey: kCIInputScaleKey)
                f.setValue(1.0, forKey: kCIInputAspectRatioKey)
                if let o = f.outputImage { ci = o }
            }
        }

        // Reduce compression noise before sharpening
        if let f = CIFilter(name: "CINoiseReduction") {
            f.setValue(ci, forKey: kCIInputImageKey)
            f.setValue(0.015 + s * 0.025, forKey: "inputNoiseLevel")
            f.setValue(0.35 + s * 0.25, forKey: "inputSharpness")
            if let o = f.outputImage { ci = o }
        }

        // Deblur / sharpen — stronger when blur is detected
        let sharpenIntensity = s * (blurScore < 100 ? 1.35 : 1.0)
        if let f = CIFilter(name: "CIUnsharpMask") {
            f.setValue(ci, forKey: kCIInputImageKey)
            f.setValue(1.5 + sharpenIntensity * 2.5, forKey: kCIInputRadiusKey)
            f.setValue(0.45 + sharpenIntensity * 0.55, forKey: kCIInputIntensityKey)
            if let o = f.outputImage { ci = o }
        }

        if let f = CIFilter(name: "CISharpenLuminance") {
            f.setValue(ci, forKey: kCIInputImageKey)
            f.setValue(0.35 + sharpenIntensity * 0.65, forKey: kCIInputSharpnessKey)
            if let o = f.outputImage { ci = o }
        }

        // Lift shadows & recover faded text
        if let f = CIFilter(name: "CIHighlightShadowAdjust") {
            f.setValue(ci, forKey: kCIInputImageKey)
            f.setValue(0.25 + s * 0.35, forKey: "inputShadowAmount")
            f.setValue(0.15 + s * 0.2, forKey: "inputHighlightAmount")
            if let o = f.outputImage { ci = o }
        }

        // Boost contrast for crisp text edges
        if let f = CIFilter(name: "CIColorControls") {
            f.setValue(ci, forKey: kCIInputImageKey)
            f.setValue(0.02 + s * 0.05, forKey: kCIInputBrightnessKey)
            f.setValue(1.05 + s * 0.3, forKey: kCIInputContrastKey)
            f.setValue(1.0, forKey: kCIInputSaturationKey)
            if let o = f.outputImage { ci = o }
        }

        guard let cg = ciContext.createCGImage(ci, from: ci.extent) else { return image }
        return UIImage(cgImage: cg, scale: image.scale, orientation: image.imageOrientation)
    }

    /// Laplacian variance — lower score = blurrier image.
    func estimateBlurScore(_ image: UIImage) -> Double {
        guard let ci = CIImage(image: image) else { return 100 }

        let scale = 400 / max(ci.extent.width, ci.extent.height)
        var input = ci
        if scale < 1, let f = CIFilter(name: "CILanczosScaleTransform") {
            f.setValue(ci, forKey: kCIInputImageKey)
            f.setValue(scale, forKey: kCIInputScaleKey)
            f.setValue(1.0, forKey: kCIInputAspectRatioKey)
            if let o = f.outputImage { input = o }
        }

        guard let matrix = CIFilter(name: "CIConvolution3X3") else { return 100 }
        matrix.setValue(input, forKey: kCIInputImageKey)
        matrix.setValue(CIVector(values: [0, 1, 0, 1, -4, 1, 0, 1, 0], count: 9), forKey: "inputWeights")
        matrix.setValue(0, forKey: "inputBias")

        guard let output = matrix.outputImage,
              let cg = ciContext.createCGImage(output, from: output.extent) else { return 100 }

        let w = cg.width, h = cg.height
        guard let data = cg.dataProvider?.data,
              let ptr = CFDataGetBytePtr(data) else { return 100 }

        let bpp = cg.bitsPerPixel / 8
        var sum: Double = 0, sumSq: Double = 0
        var count = 0

        for y in stride(from: 0, to: h, by: max(1, h / 90)) {
            for x in stride(from: 0, to: w, by: max(1, w / 90)) {
                let i = (y * w + x) * bpp
                let v = Double(ptr[i])
                sum += v; sumSq += v * v; count += 1
            }
        }

        guard count > 0 else { return 100 }
        let mean = sum / Double(count)
        return sumSq / Double(count) - mean * mean
    }

    // MARK: - Scan filters

    func applyFilter(_ filter: ScanFilter, to image: UIImage,
                     brightness: Double = 0, contrast: Double = 0) -> UIImage {
        guard var ci = CIImage(image: image) else { return image }

        // Brightness / contrast
        if brightness != 0 || contrast != 0, let f = CIFilter(name: "CIColorControls") {
            f.setValue(ci, forKey: kCIInputImageKey)
            f.setValue(brightness * 0.5, forKey: kCIInputBrightnessKey)
            f.setValue(1.0 + contrast,   forKey: kCIInputContrastKey)
            f.setValue(1.0,              forKey: kCIInputSaturationKey)
            if let o = f.outputImage { ci = o }
        }

        switch filter {
        case .none: break

        case .blackWhite:
            applyMonochrome(&ci, color: .white, brightness: 0.05, contrast: 3.0)

        case .grayscale:
            applyMonochrome(&ci, color: CIColor(red: 0.85, green: 0.85, blue: 0.85), brightness: 0, contrast: 1.0)

        case .enhanced:
            applySharpen(&ci, radius: 1.5, intensity: 0.7)
            applyColorControls(&ci, brightness: 0.1, contrast: 1.3, saturation: 0.9)

        case .document:
            applyMonochrome(&ci, color: CIColor(red: 0.9, green: 0.9, blue: 0.9), brightness: 0.04, contrast: 1.45)

        case .highContrast:
            applyMonochrome(&ci, color: .white, brightness: 0.08, contrast: 3.5)
            applySharpen(&ci, radius: 1.2, intensity: 0.5)

        case .textBoost:
            applySharpen(&ci, radius: 2.0, intensity: 0.85)
            applyMonochrome(&ci, color: CIColor(red: 0.92, green: 0.92, blue: 0.92), brightness: 0.06, contrast: 2.2)
            applyColorControls(&ci, brightness: 0.04, contrast: 1.6, saturation: 0)

        case .cleanScan:
            if let f = CIFilter(name: "CITemperatureAndTint") {
                f.setValue(ci, forKey: kCIInputImageKey)
                f.setValue(CIVector(x: 6500, y: 0), forKey: "inputNeutral")
                f.setValue(CIVector(x: 6500, y: 0), forKey: "inputTargetNeutral")
                if let o = f.outputImage { ci = o }
            }
            applyColorControls(&ci, brightness: 0.05, contrast: 1.35, saturation: 0.85)
            applySharpen(&ci, radius: 1.8, intensity: 0.6)

        case .sharpPlus:
            applySharpen(&ci, radius: 2.5, intensity: 1.0)
            if let f = CIFilter(name: "CISharpenLuminance") {
                f.setValue(ci, forKey: kCIInputImageKey)
                f.setValue(0.8, forKey: kCIInputSharpnessKey)
                if let o = f.outputImage { ci = o }
            }
            applyColorControls(&ci, brightness: 0.02, contrast: 1.2, saturation: 1.0)

        case .fadedInk:
            if let f = CIFilter(name: "CIHighlightShadowAdjust") {
                f.setValue(ci, forKey: kCIInputImageKey)
                f.setValue(0.5, forKey: "inputShadowAmount")
                f.setValue(0.1, forKey: "inputHighlightAmount")
                if let o = f.outputImage { ci = o }
            }
            applyMonochrome(&ci, color: CIColor(red: 0.15, green: 0.15, blue: 0.2), brightness: 0.1, contrast: 2.8)

        case .softLight:
            if let f = CIFilter(name: "CIHighlightShadowAdjust") {
                f.setValue(ci, forKey: kCIInputImageKey)
                f.setValue(0.6, forKey: "inputShadowAmount")
                f.setValue(0.25, forKey: "inputHighlightAmount")
                if let o = f.outputImage { ci = o }
            }
            applyColorControls(&ci, brightness: 0.08, contrast: 1.15, saturation: 0.95)

        case .magazine:
            applySharpen(&ci, radius: 1.0, intensity: 0.45)
            applyColorControls(&ci, brightness: 0.04, contrast: 1.25, saturation: 1.15)

        case .vivid:
            applyColorControls(&ci, brightness: 0.05, contrast: 1.2, saturation: 1.4)

        case .newspaper:
            applyMonochrome(&ci, color: CIColor(red: 0.88, green: 0.86, blue: 0.82), brightness: 0.03, contrast: 1.6)
            if let f = CIFilter(name: "CIColorMatrix") {
                f.setValue(ci, forKey: kCIInputImageKey)
                f.setValue(CIVector(x: 1.05, y: 0, z: 0, w: 0), forKey: "inputRVector")
                f.setValue(CIVector(x: 0, y: 1.0, z: 0, w: 0), forKey: "inputGVector")
                f.setValue(CIVector(x: 0, y: 0, z: 0.9, w: 0), forKey: "inputBVector")
                if let o = f.outputImage { ci = o }
            }

        case .aged:
            applyColorControls(&ci, brightness: 0.05, contrast: 0.9, saturation: 0.4)
            if let f = CIFilter(name: "CIColorMatrix") {
                f.setValue(ci, forKey: kCIInputImageKey)
                f.setValue(CIVector(x: 1.1, y: 0, z: 0, w: 0), forKey: "inputRVector")
                f.setValue(CIVector(x: 0, y: 0.95, z: 0, w: 0), forKey: "inputGVector")
                f.setValue(CIVector(x: 0, y: 0, z: 0.75, w: 0), forKey: "inputBVector")
                if let o = f.outputImage { ci = o }
            }

        case .scan:
            applyMonochrome(&ci, color: CIColor(red: 0.95, green: 0.95, blue: 0.95), brightness: 0.02, contrast: 1.55)
            applySharpen(&ci, radius: 1.4, intensity: 0.55)

        case .magicColor:
            if let f = CIFilter(name: "CITemperatureAndTint") {
                f.setValue(ci, forKey: kCIInputImageKey)
                f.setValue(CIVector(x: 6500, y: 0), forKey: "inputNeutral")
                f.setValue(CIVector(x: 6800, y: 0), forKey: "inputTargetNeutral")
                if let o = f.outputImage { ci = o }
            }
            applyColorControls(&ci, brightness: 0.06, contrast: 1.25, saturation: 1.2)
            applySharpen(&ci, radius: 1.2, intensity: 0.4)

        case .bw2:
            applyMonochrome(&ci, color: .white, brightness: 0.1, contrast: 4.0)
            applySharpen(&ci, radius: 1.5, intensity: 0.65)

        case .color:
            applyColorControls(&ci, brightness: 0.03, contrast: 1.15, saturation: 1.1)
            applySharpen(&ci, radius: 0.8, intensity: 0.35)

        case .photo:
            applyColorControls(&ci, brightness: 0, contrast: 1.05, saturation: 1.0)

        case .denoise:
            if let f = CIFilter(name: "CINoiseReduction") {
                f.setValue(ci, forKey: kCIInputImageKey)
                f.setValue(0.04, forKey: "inputNoiseLevel")
                f.setValue(0.5, forKey: "inputSharpness")
                if let o = f.outputImage { ci = o }
            }
            applySharpen(&ci, radius: 1.6, intensity: 0.5)
            applyColorControls(&ci, brightness: 0.03, contrast: 1.2, saturation: 0.95)

        case .inkSaver:
            applyMonochrome(&ci, color: CIColor(red: 0.2, green: 0.2, blue: 0.2), brightness: 0.15, contrast: 2.0)
            applyColorControls(&ci, brightness: 0.12, contrast: 1.1, saturation: 0)

        case .nostalgic:
            applyColorControls(&ci, brightness: 0.04, contrast: 0.95, saturation: 0.55)
            if let f = CIFilter(name: "CISepiaTone") {
                f.setValue(ci, forKey: kCIInputImageKey)
                f.setValue(0.45, forKey: kCIInputIntensityKey)
                if let o = f.outputImage { ci = o }
            }

        case .warmTone:
            if let f = CIFilter(name: "CITemperatureAndTint") {
                f.setValue(ci, forKey: kCIInputImageKey)
                f.setValue(CIVector(x: 6500, y: 0), forKey: "inputNeutral")
                f.setValue(CIVector(x: 7200, y: 0), forKey: "inputTargetNeutral")
                if let o = f.outputImage { ci = o }
            }
            applyColorControls(&ci, brightness: 0.04, contrast: 1.2, saturation: 1.05)

        case .coolTone:
            if let f = CIFilter(name: "CITemperatureAndTint") {
                f.setValue(ci, forKey: kCIInputImageKey)
                f.setValue(CIVector(x: 6500, y: 0), forKey: "inputNeutral")
                f.setValue(CIVector(x: 5800, y: 0), forKey: "inputTargetNeutral")
                if let o = f.outputImage { ci = o }
            }
            applyColorControls(&ci, brightness: 0.03, contrast: 1.25, saturation: 0.95)
            applySharpen(&ci, radius: 1.0, intensity: 0.4)

        case .invert:
            if let f = CIFilter(name: "CIColorInvert") {
                f.setValue(ci, forKey: kCIInputImageKey)
                if let o = f.outputImage { ci = o }
            }
        }

        guard let cg = ciContext.createCGImage(ci, from: ci.extent) else { return image }
        return UIImage(cgImage: cg)
    }

    // MARK: - Filter helpers

    private func applyMonochrome(_ ci: inout CIImage, color: CIColor, brightness: CGFloat, contrast: CGFloat) {
        if let f = CIFilter(name: "CIColorMonochrome") {
            f.setValue(ci, forKey: kCIInputImageKey)
            f.setValue(color, forKey: kCIInputColorKey)
            f.setValue(1.0, forKey: kCIInputIntensityKey)
            if let o = f.outputImage { ci = o }
        }
        applyColorControls(&ci, brightness: brightness, contrast: contrast, saturation: 1.0)
    }

    private func applySharpen(_ ci: inout CIImage, radius: CGFloat, intensity: CGFloat) {
        if let f = CIFilter(name: "CIUnsharpMask") {
            f.setValue(ci, forKey: kCIInputImageKey)
            f.setValue(radius, forKey: kCIInputRadiusKey)
            f.setValue(intensity, forKey: kCIInputIntensityKey)
            if let o = f.outputImage { ci = o }
        }
    }

    private func applyColorControls(_ ci: inout CIImage, brightness: CGFloat, contrast: CGFloat, saturation: CGFloat) {
        if let f = CIFilter(name: "CIColorControls") {
            f.setValue(ci, forKey: kCIInputImageKey)
            f.setValue(brightness, forKey: kCIInputBrightnessKey)
            f.setValue(contrast, forKey: kCIInputContrastKey)
            f.setValue(saturation, forKey: kCIInputSaturationKey)
            if let o = f.outputImage { ci = o }
        }
    }

    // MARK: - Crop

    func crop(image: UIImage, to rect: CGRect) -> UIImage {
        let s = image.scale
        let scaled = CGRect(x: rect.minX * s, y: rect.minY * s, width: rect.width * s, height: rect.height * s)
        guard let cg = image.cgImage?.cropping(to: scaled) else { return image }
        return UIImage(cgImage: cg, scale: s, orientation: image.imageOrientation)
    }

    // MARK: - Rotate

    func rotate(image: UIImage, degrees: Double) -> UIImage {
        let rad = CGFloat(degrees) * .pi / 180
        let newSize = CGRect(origin: .zero, size: image.size)
            .applying(CGAffineTransform(rotationAngle: rad)).size
        UIGraphicsBeginImageContextWithOptions(newSize, false, image.scale)
        let ctx = UIGraphicsGetCurrentContext()!
        ctx.translateBy(x: newSize.width / 2, y: newSize.height / 2)
        ctx.rotate(by: rad)
        image.draw(in: CGRect(x: -image.size.width / 2, y: -image.size.height / 2,
                              width: image.size.width, height: image.size.height))
        let result = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()
        return result ?? image
    }

    // MARK: - Thumbnail

    func generateThumbnail(from image: UIImage, size: CGSize = CGSize(width: 200, height: 280)) -> UIImage {
        UIGraphicsImageRenderer(size: size).image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            let ir = image.size.width / image.size.height
            let tr = size.width / size.height
            let drawRect: CGRect = ir > tr
                ? CGRect(x: 0, y: (size.height - size.width/ir)/2, width: size.width, height: size.width/ir)
                : CGRect(x: (size.width - size.height*ir)/2, y: 0, width: size.height*ir, height: size.height)
            image.draw(in: drawRect)
        }
    }
}
