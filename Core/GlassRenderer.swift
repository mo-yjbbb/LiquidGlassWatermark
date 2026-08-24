import CoreImage
import UIKit

struct WatermarkMetadata: Sendable {
    var device = ""
    var date = ""
    var exposure = ""
    var location = ""
}

final class GlassRenderer: @unchecked Sendable {
    private struct Key: Hashable { let width: Int; let height: Int }
    private struct Layers {
        let extent: CGRect
        let mask: CIImage
        let displacement: CIImage
        let overlay: CIImage
        let displacementScale: CGFloat
    }

    private let metadata: WatermarkMetadata
    private let context = CIContext(options: [.cacheIntermediates: true, .useSoftwareRenderer: false])
    private let lock = NSLock()
    private var cache: [Key: Layers] = [:]

    init(metadata: WatermarkMetadata) { self.metadata = metadata }

    func render(_ source: CIImage) -> CIImage {
        let extent = source.extent.integral
        guard extent.width > 0, extent.height > 0 else { return source }
        let layers = preparedLayers(for: extent)
        let displaced = source.clampedToExtent().applyingFilter("CIGlassDistortion", parameters: [
            "inputTexture": layers.displacement,
            kCIInputCenterKey: CIVector(x: extent.midX, y: extent.midY),
            kCIInputScaleKey: layers.displacementScale
        ]).cropped(to: extent)
        let glass = displaced.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: source,
            kCIInputMaskImageKey: layers.mask
        ])
        return layers.overlay.composited(over: glass).cropped(to: layers.extent)
    }

    func makeCGImage(_ image: CIImage) -> CGImage? {
        context.createCGImage(image, from: image.extent)
    }

    private func preparedLayers(for extent: CGRect) -> Layers {
        let key = Key(width: Int(extent.width.rounded()), height: Int(extent.height.rounded()))
        lock.lock()
        if let layers = cache[key] {
            lock.unlock()
            return layers
        }
        lock.unlock()
        let layers = makeLayers(extent: extent)
        lock.lock()
        cache[key] = layers
        lock.unlock()
        return layers
    }

    private func makeLayers(extent: CGRect) -> Layers {
        let shortSide = min(extent.width, extent.height)
        let scale = max(shortSide / 1080, 0.35)
        let margin = max(shortSide * 0.012, 8 * scale)
        let height = shortSide * 0.108
        let rect = CGRect(x: margin, y: extent.height - margin - height,
                          width: extent.width - margin * 2, height: height)
        let radius = height * 0.47

        let mask = raster(size: extent.size, opaque: false) { _ in
            UIColor.white.setFill()
            UIBezierPath(roundedRect: rect, cornerRadius: radius).fill()
        }

        let displacement = raster(size: extent.size, opaque: true) { renderer in
            let ctx = renderer.cgContext
            UIColor.black.setFill()
            ctx.fill(CGRect(origin: .zero, size: extent.size))
            let path = UIBezierPath(roundedRect: rect, cornerRadius: radius)
            ctx.saveGState()
            path.addClip()
            let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [
                UIColor(white: 0.22, alpha: 1).cgColor,
                UIColor(white: 0.72, alpha: 1).cgColor,
                UIColor(white: 0.38, alpha: 1).cgColor
            ] as CFArray, locations: [0, 0.42, 1])!
            ctx.drawLinearGradient(gradient,
                start: CGPoint(x: rect.midX, y: rect.minY),
                end: CGPoint(x: rect.midX, y: rect.maxY), options: [])
            ctx.restoreGState()
            UIColor.white.setStroke()
            path.lineWidth = max(height * 0.12, 3)
            path.stroke()
        }

        let overlay = raster(size: extent.size, opaque: false) { [metadata] renderer in
            let ctx = renderer.cgContext
            let path = UIBezierPath(roundedRect: rect, cornerRadius: radius)
            ctx.saveGState()
            path.addClip()
            let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [
                UIColor.white.withAlphaComponent(0.16).cgColor,
                UIColor.white.withAlphaComponent(0.018).cgColor,
                UIColor.black.withAlphaComponent(0.075).cgColor
            ] as CFArray, locations: [0, 0.52, 1])!
            ctx.drawLinearGradient(gradient,
                start: CGPoint(x: rect.midX, y: rect.minY),
                end: CGPoint(x: rect.midX, y: rect.maxY), options: [])
            ctx.restoreGState()

            ctx.saveGState()
            ctx.addPath(path.cgPath)
            ctx.setLineWidth(max(1.35 * scale, 1))
            ctx.replacePathWithStrokedPath()
            ctx.clip()
            let edgeHighlight = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [
                UIColor.white.withAlphaComponent(0.62).cgColor,
                UIColor.white.withAlphaComponent(0.18).cgColor,
                UIColor.white.withAlphaComponent(0).cgColor,
                UIColor.white.withAlphaComponent(0).cgColor
            ] as CFArray, locations: [0, 0.20, 0.50, 1])!
            ctx.drawLinearGradient(edgeHighlight,
                start: CGPoint(x: rect.midX, y: rect.minY),
                end: CGPoint(x: rect.midX, y: rect.maxY), options: [])
            ctx.restoreGState()

            let horizontalPadding = height * 0.34
            let leftX = rect.minX + horizontalPadding
            let leftMaxWidth = rect.width * 0.28
            let modelSize = fittedFontSize(metadata.device, base: height * 0.22,
                                           minimum: height * 0.16,
                                           maxWidth: leftMaxWidth, weight: .semibold)
            let dateSize = fittedFontSize(metadata.date, base: height * 0.16,
                                          minimum: height * 0.12,
                                          maxWidth: leftMaxWidth, weight: .regular)
            let line1 = rect.minY + height * 0.17
            let line2 = rect.minY + height * 0.56
            draw(metadata.device, at: CGPoint(x: leftX, y: line1),
                 size: modelSize, weight: .semibold)
            draw(metadata.date, at: CGPoint(x: leftX, y: line2),
                 size: dateSize, weight: .regular, alpha: 0.9)

            let rightTextMaxWidth = rect.width * 0.255
            let parameterSize = fittedFontSize(metadata.exposure, base: height * 0.18,
                                               minimum: height * 0.125,
                                               maxWidth: rightTextMaxWidth, weight: .medium)
            let locationSize = fittedFontSize(metadata.location, base: height * 0.15,
                                              minimum: height * 0.105,
                                              maxWidth: rightTextMaxWidth, weight: .regular)
            let rightTextWidth = max(textWidth(metadata.exposure, size: parameterSize, weight: .medium),
                                     textWidth(metadata.location, size: locationSize, weight: .regular))
            let rightX = rect.maxX - horizontalPadding - rightTextWidth
            let logoSize = height * 0.47
            let logoWidth = textWidth("", size: logoSize, weight: .medium)
            let logoX = rightX - height * 0.20 - logoWidth
            let logoHeight = UIFont.systemFont(ofSize: logoSize, weight: .medium).lineHeight
            draw("", at: CGPoint(x: logoX, y: rect.midY - logoHeight * 0.5),
                 size: logoSize, weight: .medium)
            draw(metadata.exposure, at: CGPoint(x: rightX, y: rect.minY + height * 0.19),
                 size: parameterSize, weight: .medium)
            draw(metadata.location, at: CGPoint(x: rightX, y: rect.minY + height * 0.56),
                 size: locationSize, weight: .regular, alpha: 0.9)
        }

        return Layers(extent: extent, mask: mask, displacement: displacement,
                      overlay: overlay, displacementScale: height * 0.88)
    }

    private func raster(size: CGSize, opaque: Bool,
                        drawing: (UIGraphicsImageRendererContext) -> Void) -> CIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = opaque
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

private func textWidth(_ text: String, size: CGFloat, weight: UIFont.Weight) -> CGFloat {
    (text as NSString).size(withAttributes: [
        .font: UIFont.systemFont(ofSize: size, weight: weight)
    ]).width
}

private func fittedFontSize(_ text: String, base: CGFloat, minimum: CGFloat,
                            maxWidth: CGFloat, weight: UIFont.Weight) -> CGFloat {
    guard !text.isEmpty else { return base }
    let width = textWidth(text, size: base, weight: weight)
    guard width > maxWidth, width > 0 else { return base }
    return max(minimum, base * maxWidth / width)
}

