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
        let displaced = source.clampedToExtent().applyingFilter("CIDisplacementDistortion", parameters: [
            kCIInputDisplacementImageKey: layers.displacement,
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
        let scale = max(min(extent.width, extent.height) / 1080, 0.65)
        let margin = max(18 * scale, extent.width * 0.012)
        let height = min(max(extent.height * 0.155, 164 * scale), extent.height * 0.22)
        let rect = CGRect(x: margin, y: extent.height - margin - height,
                          width: extent.width - margin * 2, height: height)
        let radius = height * 0.47

        let mask = raster(size: extent.size, opaque: false) { _ in
            UIColor.white.setFill()
            UIBezierPath(roundedRect: rect, cornerRadius: radius).fill()
        }

        let displacement = raster(size: extent.size, opaque: true) { renderer in
            let ctx = renderer.cgContext
            UIColor(white: 0.5, alpha: 1).setFill()
            ctx.fill(CGRect(origin: .zero, size: extent.size))
            let path = UIBezierPath(roundedRect: rect, cornerRadius: radius)
            ctx.saveGState()
            path.addClip()
            let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [
                UIColor(red: 0.43, green: 0.55, blue: 0.5, alpha: 1).cgColor,
                UIColor(red: 0.58, green: 0.47, blue: 0.5, alpha: 1).cgColor,
                UIColor(red: 0.47, green: 0.54, blue: 0.5, alpha: 1).cgColor
            ] as CFArray, locations: [0, 0.5, 1])!
            ctx.drawLinearGradient(gradient,
                start: CGPoint(x: rect.minX, y: rect.midY),
                end: CGPoint(x: rect.maxX, y: rect.midY), options: [])
            ctx.restoreGState()
        }

        let overlay = raster(size: extent.size, opaque: false) { [metadata] renderer in
            let ctx = renderer.cgContext
            let path = UIBezierPath(roundedRect: rect, cornerRadius: radius)
            ctx.saveGState()
            path.addClip()
            let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [
                UIColor.white.withAlphaComponent(0.23).cgColor,
                UIColor.white.withAlphaComponent(0.035).cgColor,
                UIColor.black.withAlphaComponent(0.13).cgColor
            ] as CFArray, locations: [0, 0.52, 1])!
            ctx.drawLinearGradient(gradient,
                start: CGPoint(x: rect.midX, y: rect.minY),
                end: CGPoint(x: rect.midX, y: rect.maxY), options: [])
            ctx.restoreGState()

            UIColor.white.withAlphaComponent(0.82).setStroke()
            path.lineWidth = max(2.2 * scale, 1.5)
            path.stroke()
            let inner = UIBezierPath(roundedRect: rect.insetBy(dx: 4 * scale, dy: 4 * scale),
                                     cornerRadius: radius - 4 * scale)
            UIColor.black.withAlphaComponent(0.24).setStroke()
            inner.lineWidth = max(scale, 1)
            inner.stroke()

            let leftX = rect.minX + 48 * scale
            let line1 = rect.minY + height * 0.23
            let line2 = rect.minY + height * 0.61
            draw(metadata.device, at: CGPoint(x: leftX, y: line1),
                 size: 35 * scale, weight: .semibold)
            draw(metadata.date, at: CGPoint(x: leftX, y: line2),
                 size: 24 * scale, weight: .regular, alpha: 0.9)

            let rightX = rect.maxX - min(rect.width * 0.32, 640 * scale)
            draw("", at: CGPoint(x: rightX - 80 * scale, y: line1 - 12 * scale),
                 size: 62 * scale, weight: .medium)
            draw(metadata.exposure, at: CGPoint(x: rightX, y: line1),
                 size: 28 * scale, weight: .medium)
            draw(metadata.location, at: CGPoint(x: rightX, y: line2),
                 size: 22 * scale, weight: .regular, alpha: 0.9)
        }

        return Layers(extent: extent, mask: mask, displacement: displacement,
                      overlay: overlay, displacementScale: 46 * scale)
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

