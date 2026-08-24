import CoreImage
import CoreImage.CIFilterBuiltins
import UIKit

struct WatermarkMetadata: Sendable {
    var device = "iPhone"
    var date = ""
    var exposure = "24mm  F1.8  1/100s  ISO100"
    var location = ""
}

final class GlassRenderer: @unchecked Sendable {
    private let metadata: WatermarkMetadata
    private let context = CIContext(options: [.cacheIntermediates: true])

    init(metadata: WatermarkMetadata) { self.metadata = metadata }

    func render(_ source: CIImage) -> CIImage {
        let extent = source.extent.integral
        guard extent.width > 0, extent.height > 0 else { return source }
        let scale = max(extent.width / 1920, 0.5)
        let margin = max(16 * scale, extent.width * 0.012)
        let panelHeight = min(max(132 * scale, extent.height * 0.12), extent.height * 0.19)
        let radius = panelHeight * 0.48
        let panelRect = CGRect(x: margin, y: margin, width: extent.width - margin * 2, height: panelHeight)

        let mask = rasterImage(size: extent.size) { ctx in
            ctx.setFillColor(UIColor.white.cgColor)
            ctx.addPath(UIBezierPath(roundedRect: panelRect, cornerRadius: radius).cgPath)
            ctx.fillPath()
        }

        let blurred = source.clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 22 * scale])
            .cropped(to: extent)
        let glassBase = blurred.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: source,
            kCIInputMaskImageKey: mask
        ])

        let overlay = rasterImage(size: extent.size) { [metadata] ctx in
            let path = UIBezierPath(roundedRect: panelRect, cornerRadius: radius)
            ctx.setFillColor(UIColor.white.withAlphaComponent(0.13).cgColor)
            ctx.addPath(path.cgPath)
            ctx.fillPath()
            ctx.setStrokeColor(UIColor.white.withAlphaComponent(0.55).cgColor)
            ctx.setLineWidth(max(1.2 * scale, 1))
            ctx.addPath(path.cgPath)
            ctx.strokePath()

            let leftX = panelRect.minX + 58 * scale
            let mainY = extent.height - panelRect.maxY + 34 * scale
            let secondaryY = mainY + 49 * scale
            draw(metadata.device, at: CGPoint(x: leftX, y: mainY), size: 30 * scale, weight: .semibold)
            draw(metadata.date, at: CGPoint(x: leftX, y: secondaryY), size: 22 * scale, weight: .regular, alpha: 0.86)

            let apple = "●"
            let rightBlockX = panelRect.maxX - min(panelRect.width * 0.28, 520 * scale)
            draw(apple, at: CGPoint(x: rightBlockX - 62 * scale, y: mainY - 5 * scale), size: 48 * scale, weight: .bold)
            draw(metadata.exposure, at: CGPoint(x: rightBlockX, y: mainY), size: 25 * scale, weight: .medium)
            draw(metadata.location, at: CGPoint(x: rightBlockX, y: secondaryY), size: 20 * scale, weight: .regular, alpha: 0.86)
        }
        return overlay.composited(over: glassBase).cropped(to: extent)
    }

    func makeCGImage(_ image: CIImage) -> CGImage? {
        context.createCGImage(image, from: image.extent)
    }

    private func rasterImage(size: CGSize, drawing: (CGContext) -> Void) -> CIImage {
        let width = max(Int(size.width.rounded()), 1)
        let height = max(Int(size.height.rounded()), 1)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                  bytesPerRow: width * 4, space: colorSpace,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return CIImage.empty()
        }
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: 1, y: -1)
        UIGraphicsPushContext(ctx)
        drawing(ctx)
        UIGraphicsPopContext()
        guard let cg = ctx.makeImage() else { return CIImage.empty() }
        return CIImage(cgImage: cg)
    }
}

private func draw(_ text: String, at point: CGPoint, size: CGFloat, weight: UIFont.Weight, alpha: CGFloat = 1) {
    guard !text.isEmpty else { return }
    let attributes: [NSAttributedString.Key: Any] = [
        .font: UIFont.systemFont(ofSize: size, weight: weight),
        .foregroundColor: UIColor.white.withAlphaComponent(alpha)
    ]
    (text as NSString).draw(at: point, withAttributes: attributes)
}

