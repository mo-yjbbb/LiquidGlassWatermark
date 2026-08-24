import CoreImage
import UIKit

struct WatermarkMetadata: Sendable {
    var device = ""
    var date = ""
    var exposure = ""
    var location = ""
}

final class GlassRenderer: @unchecked Sendable {
    private let metadata: WatermarkMetadata
    private let context = CIContext(options: [.cacheIntermediates: true])

    init(metadata: WatermarkMetadata) { self.metadata = metadata }

    func render(_ source: CIImage) -> CIImage {
        let extent = source.extent.integral
        guard extent.width > 0, extent.height > 0 else { return source }
        let scale = max(min(extent.width, extent.height) / 1080, 0.65)
        let margin = max(18 * scale, extent.width * 0.012)
        let height = min(max(extent.height * 0.155, 164 * scale), extent.height * 0.22)
        let rect = CGRect(x: margin, y: extent.height - margin - height,
                          width: extent.width - margin * 2, height: height)
        let radius = height * 0.47

        let mask = raster(size: extent.size) { _ in
            UIColor.white.setFill()
            UIBezierPath(roundedRect: rect, cornerRadius: radius).fill()
        }
        let texture = raster(size: extent.size) { renderer in
            let ctx = renderer.cgContext
            let path = UIBezierPath(roundedRect: rect, cornerRadius: radius)
            ctx.saveGState()
            path.addClip()
            let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                colors: [UIColor(white: 0.12, alpha: 1).cgColor,
                         UIColor(white: 0.9, alpha: 1).cgColor,
                         UIColor(white: 0.36, alpha: 1).cgColor] as CFArray,
                locations: [0, 0.32, 1])!
            ctx.drawLinearGradient(gradient,
                start: CGPoint(x: rect.midX, y: rect.minY),
                end: CGPoint(x: rect.midX, y: rect.maxY), options: [])
            ctx.restoreGState()
            UIColor.white.setStroke()
            path.lineWidth = max(12 * scale, 6)
            path.stroke()
        }

        let refracted = source.clampedToExtent().applyingFilter("CIGlassDistortion", parameters: [
            "inputTexture": texture,
            kCIInputCenterKey: CIVector(x: rect.midX, y: extent.height - rect.midY),
            kCIInputScaleKey: 82 * scale
        ]).cropped(to: extent)
        let base = refracted.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: source,
            kCIInputMaskImageKey: mask
        ])

        let overlay = raster(size: extent.size) { [metadata] renderer in
            let ctx = renderer.cgContext
            let path = UIBezierPath(roundedRect: rect, cornerRadius: radius)
            ctx.saveGState()
            path.addClip()
            let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                colors: [UIColor.white.withAlphaComponent(0.25).cgColor,
                         UIColor.white.withAlphaComponent(0.045).cgColor,
                         UIColor.black.withAlphaComponent(0.14).cgColor] as CFArray,
                locations: [0, 0.5, 1])!
            ctx.drawLinearGradient(gradient,
                start: CGPoint(x: rect.midX, y: rect.minY),
                end: CGPoint(x: rect.midX, y: rect.maxY), options: [])
            ctx.restoreGState()

            UIColor.white.withAlphaComponent(0.76).setStroke()
            path.lineWidth = max(1.8 * scale, 1.5)
            path.stroke()
            let inner = UIBezierPath(roundedRect: rect.insetBy(dx: 3 * scale, dy: 3 * scale),
                                     cornerRadius: radius - 3 * scale)
            UIColor.black.withAlphaComponent(0.25).setStroke()
            inner.lineWidth = max(scale, 1)
            inner.stroke()

            let leftX = rect.minX + 48 * scale
            let line1 = rect.minY + height * 0.23
            let line2 = rect.minY + height * 0.61
            draw(metadata.device.isEmpty ? "iPhone" : metadata.device,
                 at: CGPoint(x: leftX, y: line1), size: 35 * scale, weight: .semibold)
            draw(metadata.date, at: CGPoint(x: leftX, y: line2),
                 size: 24 * scale, weight: .regular, alpha: 0.9)

            let rightX = rect.maxX - min(rect.width * 0.32, 640 * scale)
            draw("", at: CGPoint(x: rightX - 80 * scale, y: line1 - 12 * scale),
                 size: 62 * scale, weight: .medium)
            draw(metadata.exposure.isEmpty ? "无可用拍摄参数" : metadata.exposure,
                 at: CGPoint(x: rightX, y: line1), size: 28 * scale, weight: .medium)
            draw(metadata.location, at: CGPoint(x: rightX, y: line2),
                 size: 22 * scale, weight: .regular, alpha: 0.9)
        }
        return overlay.composited(over: base).cropped(to: extent)
    }

    func makeCGImage(_ image: CIImage) -> CGImage? {
        context.createCGImage(image, from: image.extent)
    }

    private func raster(size: CGSize, drawing: (UIGraphicsImageRendererContext) -> Void) -> CIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let image = UIGraphicsImageRenderer(size: size, format: format).image(actions: drawing)
        return CIImage(image: image)?.cropped(to: CGRect(origin: .zero, size: size)) ?? .empty()
    }
}

private func draw(_ text: String, at point: CGPoint, size: CGFloat,
                  weight: UIFont.Weight, alpha: CGFloat = 1) {
    guard !text.isEmpty else { return }
    let shadow = NSShadow()
    shadow.shadowColor = UIColor.black.withAlphaComponent(0.45)
    shadow.shadowBlurRadius = max(size * 0.11, 1)
    shadow.shadowOffset = CGSize(width: 0, height: 1)
    (text as NSString).draw(at: point, withAttributes: [
        .font: UIFont.systemFont(ofSize: size, weight: weight),
        .foregroundColor: UIColor.white.withAlphaComponent(alpha),
        .shadow: shadow
    ])
}

