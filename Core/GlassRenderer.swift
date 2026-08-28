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
        let blurRadius: CGFloat
        let lensPoint0: CGPoint
        let lensPoint1: CGPoint
        let lensRadius: CGFloat
    }

    private let metadata: WatermarkMetadata
    private let context = CIContext(options: [.cacheIntermediates: false, .useSoftwareRenderer: false])
    private let lock = NSLock()
    private var cache: [Key: Layers] = [:]

    init(metadata: WatermarkMetadata) { self.metadata = metadata }

    func render(_ source: CIImage) -> CIImage {
        let extent = source.extent.integral
        guard !extent.isInfinite, !extent.isNull,
              extent.origin.x.isFinite, extent.origin.y.isFinite,
              extent.width.isFinite, extent.height.isFinite,
              extent.width > 0, extent.height > 0 else { return source }
        let layers = preparedLayers(for: extent)
        let opticalSource = source.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [
            kCIInputRadiusKey: layers.blurRadius
        ])
        let refracted = opticalSource.applyingFilter("CIGlassLozenge", parameters: [
            "inputPoint0": CIVector(cgPoint: layers.lensPoint0),
            "inputPoint1": CIVector(cgPoint: layers.lensPoint1),
            "inputRadius": layers.lensRadius,
            "inputRefraction": 1.10
        ])
        let displaced = refracted.applyingFilter("CIDisplacementDistortion", parameters: [
            "inputDisplacementImage": layers.displacement,
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
        // Core Image uses a bottom-left origin. Keep the capsule at the visual bottom.
        let rect = CGRect(x: extent.minX + margin, y: extent.minY + margin,
                          width: extent.width - margin * 2, height: height)
        let radius = height * 0.47
        let panelRect = CGRect(origin: .zero, size: rect.size)
        let placement = CGAffineTransform(translationX: rect.minX, y: rect.minY)

        let maskPanel = raster(size: panelRect.size, opaque: false) { _ in
            UIColor.white.setFill()
            UIBezierPath(roundedRect: panelRect, cornerRadius: radius).fill()
        }
        let mask = maskPanel.transformed(by: placement)

        let displacementPanel = raster(size: panelRect.size, opaque: true) { renderer in
            let rect = panelRect
            let ctx = renderer.cgContext
            UIColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1).setFill()
            ctx.fill(panelRect)
            let path = UIBezierPath(roundedRect: rect, cornerRadius: radius)
            ctx.saveGState()
            path.addClip()
            UIColor.black.setFill()
            ctx.fill(rect)
            let horizontal = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [
                UIColor(red: 0.08, green: 0, blue: 0.25, alpha: 1).cgColor,
                UIColor(red: 0.30, green: 0, blue: 0.25, alpha: 1).cgColor,
                UIColor(red: 0.50, green: 0, blue: 0.25, alpha: 1).cgColor,
                UIColor(red: 0.50, green: 0, blue: 0.25, alpha: 1).cgColor,
                UIColor(red: 0.70, green: 0, blue: 0.25, alpha: 1).cgColor,
                UIColor(red: 0.92, green: 0, blue: 0.25, alpha: 1).cgColor
            ] as CFArray, locations: [0, 0.075, 0.20, 0.80, 0.925, 1])!
            ctx.drawLinearGradient(horizontal,
                start: CGPoint(x: rect.minX, y: rect.midY),
                end: CGPoint(x: rect.maxX, y: rect.midY), options: [])
            ctx.setBlendMode(.plusLighter)
            let vertical = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [
                UIColor(red: 0, green: 0.08, blue: 0.25, alpha: 1).cgColor,
                UIColor(red: 0, green: 0.30, blue: 0.25, alpha: 1).cgColor,
                UIColor(red: 0, green: 0.50, blue: 0.25, alpha: 1).cgColor,
                UIColor(red: 0, green: 0.50, blue: 0.25, alpha: 1).cgColor,
                UIColor(red: 0, green: 0.70, blue: 0.25, alpha: 1).cgColor,
                UIColor(red: 0, green: 0.92, blue: 0.25, alpha: 1).cgColor
            ] as CFArray, locations: [0, 0.10, 0.24, 0.76, 0.90, 1])!
            ctx.drawLinearGradient(vertical,
                start: CGPoint(x: rect.midX, y: rect.minY),
                end: CGPoint(x: rect.midX, y: rect.maxY), options: [])
            ctx.restoreGState()
        }
        let neutralDisplacement = CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5))
            .cropped(to: extent)
        let displacement = displacementPanel.transformed(by: placement)
            .composited(over: neutralDisplacement)

        let overlayPanel = raster(size: panelRect.size, opaque: false) { [metadata] renderer in
            let rect = panelRect
            let ctx = renderer.cgContext
            let path = UIBezierPath(roundedRect: rect, cornerRadius: radius)
            ctx.saveGState()
            path.addClip()
            let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [
                UIColor.white.withAlphaComponent(0.026).cgColor,
                UIColor.white.withAlphaComponent(0.004).cgColor,
                UIColor.black.withAlphaComponent(0.008).cgColor
            ] as CFArray, locations: [0, 0.52, 1])!
            ctx.drawLinearGradient(gradient,
                start: CGPoint(x: rect.midX, y: rect.minY),
                end: CGPoint(x: rect.midX, y: rect.maxY), options: [])
            ctx.restoreGState()

            // Broad diagonal reflections make the surface read as a curved
            // lens instead of a uniformly transparent rectangle.
            ctx.saveGState()
            path.addClip()
            let reflection = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [
                UIColor.white.withAlphaComponent(0.16).cgColor,
                UIColor.white.withAlphaComponent(0.028).cgColor,
                UIColor.white.withAlphaComponent(0).cgColor
            ] as CFArray, locations: [0, 0.38, 1])!
            ctx.drawRadialGradient(reflection,
                startCenter: CGPoint(x: rect.minX + rect.width * 0.12, y: rect.minY + height * 0.08),
                startRadius: 0,
                endCenter: CGPoint(x: rect.minX + rect.width * 0.18, y: rect.minY + height * 0.20),
                endRadius: rect.width * 0.30,
                options: [])
            ctx.restoreGState()

            // One very thin highlight at the physical outer rim. Expanding
            // the stroke path beyond the raster bounds keeps its inner half
            // from reading as a second concentric rounded rectangle.
            ctx.saveGState()
            let rimWidth = max(0.95 * scale, 0.65)
            let rimPath = UIBezierPath(roundedRect: rect.insetBy(dx: -rimWidth * 0.55,
                                                                 dy: -rimWidth * 0.55),
                                       cornerRadius: radius + rimWidth * 0.55)
            ctx.addPath(rimPath.cgPath)
            ctx.setLineWidth(rimWidth)
            ctx.replacePathWithStrokedPath()
            ctx.clip()
            let edgeHighlight = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [
                UIColor.white.withAlphaComponent(0.38).cgColor,
                UIColor.white.withAlphaComponent(0.12).cgColor,
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

            let rightTextMaxWidth = rect.width * 0.245
            let parameterSize = fittedFontSize(metadata.exposure, base: height * 0.18,
                                               minimum: height * 0.125,
                                               maxWidth: rightTextMaxWidth, weight: .medium)
            let locationSize = fittedFontSize(metadata.location, base: height * 0.15,
                                              minimum: height * 0.105,
                                              maxWidth: rightTextMaxWidth, weight: .regular)
            let rightTextWidth = max(textWidth(metadata.exposure, size: parameterSize, weight: .medium),
                                     textWidth(metadata.location, size: locationSize, weight: .regular))
            let rightX = rect.maxX - horizontalPadding - rightTextWidth
            let separatorX = rightX - height * 0.18
            let parameterLineHeight = UIFont.systemFont(ofSize: parameterSize, weight: .medium).lineHeight
            let locationLineHeight = UIFont.systemFont(ofSize: locationSize, weight: .regular).lineHeight
            let groupHeight = max(height * 0.50,
                                  parameterLineHeight + locationLineHeight + height * 0.035)
            let groupMinY = rect.midY - groupHeight * 0.5
            let groupMaxY = groupMinY + groupHeight
            let logoLineHeightRatio = UIFont.systemFont(ofSize: 100, weight: .medium).lineHeight / 100
            let logoSize = groupHeight / logoLineHeightRatio
            let logoWidth = textWidth("", size: logoSize, weight: .medium)
            let logoX = separatorX - height * 0.16 - logoWidth
            draw("", at: CGPoint(x: logoX, y: groupMinY),
                 size: logoSize, weight: .medium)

            ctx.saveGState()
            ctx.setStrokeColor(UIColor.white.withAlphaComponent(0.62).cgColor)
            ctx.setLineWidth(max(scale * 1.05, 0.8))
            ctx.move(to: CGPoint(x: separatorX, y: groupMinY))
            ctx.addLine(to: CGPoint(x: separatorX, y: groupMaxY))
            ctx.strokePath()
            ctx.restoreGState()

            draw(metadata.exposure, at: CGPoint(x: rightX, y: groupMinY),
                 size: parameterSize, weight: .medium)
            draw(metadata.location, at: CGPoint(x: rightX, y: groupMaxY - locationLineHeight),
                 size: locationSize, weight: .regular, alpha: 0.9)
        }
        let overlay = overlayPanel.transformed(by: placement)

        return Layers(extent: extent, mask: mask, displacement: displacement,
                      overlay: overlay, displacementScale: height * 0.105,
                      blurRadius: max(height * 0.0012, 0.10),
                      lensPoint0: CGPoint(x: rect.minX + radius, y: rect.midY),
                      lensPoint1: CGPoint(x: rect.maxX - radius, y: rect.midY),
                      lensRadius: radius * 0.985)
    }

    private func raster(size: CGSize, opaque: Bool,
                        drawing: (UIGraphicsImageRendererContext) -> Void) -> CIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = opaque
        let image = UIGraphicsImageRenderer(size: size, format: format).image(actions: drawing)
        return CIImage(image: image)?.cropped(to: CGRect(origin: .zero, size: size)) ?? .empty()
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
}
