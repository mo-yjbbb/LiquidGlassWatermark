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
        let rimMask: CIImage
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
        // Keep the interior optically clear. Liquid depth comes from gentle
        // refraction and reflections, not a frosted/blurred fill.
        let opticalSource = source.clampedToExtent()
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
        // The physical rim reflects the actual pixels underneath it. Bright
        // and colourful areas therefore create stronger coloured highlights,
        // while dark areas stay subtle instead of receiving a painted line.
        let liftedSource = source.applyingFilter("CIColorControls", parameters: [
            kCIInputSaturationKey: 1.12,
            kCIInputBrightnessKey: 0.012,
            kCIInputContrastKey: 1.10
        ])
        let reflectedRim = liftedSource.applyingFilter("CIScreenBlendMode", parameters: [
            kCIInputBackgroundImageKey: glass
        ]).cropped(to: extent)
        let opticallyRimmed = reflectedRim.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: glass,
            kCIInputMaskImageKey: layers.rimMask
        ])

        // Sub-pixel RGB separation at the curved rim simulates wavelength
        // diffraction. It is derived entirely from the photo underneath and
        // remains confined to the optical rim mask.
        let spectralOffset = max(min(extent.width, extent.height) * 0.00115, 0.55)
        let red = source.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 0.22, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 0)
        ]).transformed(by: CGAffineTransform(translationX: spectralOffset, y: 0))
        let green = source.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: 0.15, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 0)
        ])
        let blue = source.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: 0.22, w: 0)
        ]).transformed(by: CGAffineTransform(translationX: -spectralOffset, y: 0))
        let spectrum = red.applyingFilter("CIAdditionCompositing", parameters: [
            kCIInputBackgroundImageKey: green
        ]).applyingFilter("CIAdditionCompositing", parameters: [
            kCIInputBackgroundImageKey: blue
        ]).cropped(to: extent)
        let diffractedRim = spectrum.applyingFilter("CIScreenBlendMode", parameters: [
            kCIInputBackgroundImageKey: opticallyRimmed
        ])
        let liquidGlass = diffractedRim.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: opticallyRimmed,
            kCIInputMaskImageKey: layers.rimMask
        ])
        return layers.overlay.composited(over: liquidGlass).cropped(to: layers.extent)
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

        let opticalRimWidth = max(height * 0.032, 0.9 * scale)
        let rimMaskPanel = raster(size: panelRect.size, opaque: false) { renderer in
            let ctx = renderer.cgContext
            ctx.setLineWidth(opticalRimWidth)
            ctx.addPath(UIBezierPath(
                roundedRect: panelRect.insetBy(dx: -opticalRimWidth * 0.55,
                                               dy: -opticalRimWidth * 0.55),
                cornerRadius: radius + opticalRimWidth * 0.55
            ).cgPath)
            ctx.replacePathWithStrokedPath()
            ctx.clip()
            let directional = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [
                UIColor.white.withAlphaComponent(0.72).cgColor,
                UIColor.white.withAlphaComponent(0.13).cgColor,
                UIColor.white.withAlphaComponent(0).cgColor,
                UIColor.white.withAlphaComponent(0.08).cgColor,
                UIColor.white.withAlphaComponent(0.48).cgColor
            ] as CFArray, locations: [0, 0.17, 0.50, 0.82, 1])!
            ctx.drawLinearGradient(directional,
                start: CGPoint(x: panelRect.midX, y: panelRect.minY),
                end: CGPoint(x: panelRect.midX, y: panelRect.maxY), options: [])
        }
        let rimMask = rimMaskPanel.transformed(by: placement)

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
            // Transparent optical reflections cover the complete capsule.
            // These are highlights only (no translucent fill), so the centre
            // keeps the same clarity while still reading as curved glass.
            ctx.saveGState()
            path.addClip()
            ctx.setBlendMode(.screen)
            // A very soft travelling specular band gives the middle of the
            // lens a liquid response without turning it milky.
            let specular = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [
                UIColor.white.withAlphaComponent(0).cgColor,
                UIColor.white.withAlphaComponent(0.018).cgColor,
                UIColor.white.withAlphaComponent(0).cgColor
            ] as CFArray, locations: [0, 0.5, 1])!
            ctx.drawLinearGradient(specular,
                start: CGPoint(x: rect.minX + rect.width * 0.18, y: rect.minY),
                end: CGPoint(x: rect.maxX - rect.width * 0.18, y: rect.maxY), options: [])
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
            let brand = brandMark(for: metadata.device)
            let logoWidth = min(groupHeight * brandAspectRatio(brand), height * 1.55)
            let logoX = separatorX - height * 0.16 - logoWidth
            drawBrandMark(brand, in: CGRect(x: logoX, y: groupMinY,
                                            width: logoWidth, height: groupHeight),
                          context: ctx)

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

        return Layers(extent: extent, mask: mask, rimMask: rimMask, displacement: displacement,
                      overlay: overlay, displacementScale: height * 0.105,
                      blurRadius: 0,
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

private enum BrandMark {
    case apple, leica, xmage, hasselblad, zeiss, iqoo, honor
    case word(String, UIFont.Weight)
    case camera
}

private func brandMark(for device: String) -> BrandMark {
    let value = device.lowercased()
    if value.contains("iphone") || value.contains("apple") { return .apple }
    // Prefer the imaging partner used by the phone family. When no known
    // partnership exists, fall back to the device maker's own word mark.
    if value.contains("xiaomi") || value.contains("redmi") || value.contains("poco") {
        return .leica
    }
    if value.contains("huawei") { return .xmage }
    if value.contains("honor") { return .honor }
    if value.contains("oneplus") || value.contains("one plus") || value.contains("oppo") {
        return .hasselblad
    }
    if value.contains("iqoo") { return .iqoo }
    if value.contains("vivo") { return .zeiss }
    if value.contains("samsung") || value.contains("galaxy") { return .word("SAMSUNG", .bold) }
    if value.contains("google") || value.contains("pixel") { return .word("G", .bold) }
    if value.contains("sony") || value.contains("xperia") { return .word("SONY", .semibold) }
    if value.contains("realme") { return .word("realme", .bold) }
    if value.contains("motorola") || value.hasPrefix("moto") { return .word("M", .bold) }
    if value.contains("nubia") || value.contains("redmagic") { return .word("nubia", .semibold) }
    if value.contains("leica") { return .leica }
    if value.contains("nikon") { return .word("Nikon", .bold) }
    if value.contains("canon") { return .word("Canon", .bold) }
    if value.contains("fujifilm") || value.contains("fuji") { return .word("FUJI", .bold) }
    return .camera
}

private func brandAspectRatio(_ mark: BrandMark) -> CGFloat {
    switch mark {
    case .apple, .leica, .hasselblad, .camera: return 1
    case .zeiss: return 1.05
    case .xmage: return 1.9
    case .iqoo: return 2.05
    case .honor: return 2.4
    case .word(let text, _): return max(0.8, min(CGFloat(text.count) * 0.62, 2.5))
    }
}

private func drawBrandMark(_ mark: BrandMark, in rect: CGRect, context ctx: CGContext) {
    ctx.saveGState()
    defer { ctx.restoreGState() }

    func centeredText(_ text: String, font: UIFont, color: UIColor) {
        let size = (text as NSString).size(withAttributes: [.font: font])
        (text as NSString).draw(at: CGPoint(x: rect.midX - size.width * 0.5,
                                            y: rect.midY - size.height * 0.5),
                                withAttributes: [.font: font, .foregroundColor: color])
    }

    switch mark {
    case .apple:
        let font = UIFont.systemFont(ofSize: rect.height * 0.83, weight: .medium)
        centeredText("", font: font, color: .white)
    case .leica:
        let circle = CGRect(x: rect.midX - rect.height * 0.48,
                            y: rect.midY - rect.height * 0.48,
                            width: rect.height * 0.96, height: rect.height * 0.96)
        UIColor(red: 0.93, green: 0, blue: 0.08, alpha: 1).setFill()
        UIBezierPath(ovalIn: circle).fill()
        let font = UIFont(name: "SnellRoundhand-Bold", size: rect.height * 0.35)
            ?? UIFont.italicSystemFont(ofSize: rect.height * 0.32)
        centeredText("Leica", font: font, color: .white)
    case .xmage:
        let font = UIFont.systemFont(ofSize: rect.height * 0.53, weight: .bold)
        centeredText("XMAGE", font: font,
                     color: UIColor(red: 0.78, green: 0, blue: 0.16, alpha: 1))
    case .hasselblad:
        let diameter = min(rect.width, rect.height) * 0.96
        let badge = CGRect(x: rect.midX - diameter * 0.5, y: rect.midY - diameter * 0.5,
                           width: diameter, height: diameter)
        UIColor.black.withAlphaComponent(0.88).setFill()
        UIBezierPath(ovalIn: badge).fill()
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: badge.minX + badge.width * x, y: badge.minY + badge.height * y)
        }
        UIColor.white.setFill()
        let left = UIBezierPath()
        left.move(to: point(0.35, 0.22)); left.addLine(to: point(0.49, 0.22))
        left.addLine(to: point(0.38, 0.80)); left.addLine(to: point(0.24, 0.80)); left.close(); left.fill()
        let right = UIBezierPath()
        right.move(to: point(0.61, 0.20)); right.addLine(to: point(0.75, 0.20))
        right.addLine(to: point(0.64, 0.78)); right.addLine(to: point(0.50, 0.78)); right.close(); right.fill()
        let bridge = UIBezierPath()
        bridge.move(to: point(0.27, 0.46)); bridge.addLine(to: point(0.68, 0.46))
        bridge.addLine(to: point(0.65, 0.59)); bridge.addLine(to: point(0.24, 0.59)); bridge.close(); bridge.fill()
    case .zeiss:
        let badge = rect.insetBy(dx: rect.width * 0.04, dy: rect.height * 0.04)
        let path = UIBezierPath()
        path.move(to: CGPoint(x: badge.minX, y: badge.minY))
        path.addLine(to: CGPoint(x: badge.maxX, y: badge.minY))
        path.addLine(to: CGPoint(x: badge.maxX, y: badge.minY + badge.height * 0.96))
        path.addQuadCurve(to: CGPoint(x: badge.minX, y: badge.minY + badge.height * 0.96),
                          controlPoint: CGPoint(x: badge.midX, y: badge.minY + badge.height * 0.70))
        path.close()
        UIColor(red: 0.10, green: 0.18, blue: 0.62, alpha: 1).setFill()
        path.fill()
        centeredText("ZEISS", font: UIFont.systemFont(ofSize: rect.height * 0.34,
                                                       weight: .bold), color: .white)
    case .iqoo:
        centeredText("iQOO", font: UIFont.systemFont(ofSize: rect.height * 0.54,
                                                      weight: .medium),
                     color: UIColor(red: 0.96, green: 0.66, blue: 0.02, alpha: 1))
    case .honor:
        let iconSize = rect.height * 0.72
        let icon = CGRect(x: rect.minX, y: rect.midY - iconSize * 0.5,
                          width: iconSize, height: iconSize)
        ctx.setStrokeColor(UIColor.white.cgColor)
        ctx.setLineWidth(max(iconSize * 0.16, 1))
        ctx.setLineCap(.butt)
        for start in stride(from: CGFloat.pi * 0.08, to: CGFloat.pi * 2, by: CGFloat.pi * 0.5) {
            ctx.addArc(center: CGPoint(x: icon.midX, y: icon.midY),
                       radius: iconSize * 0.36, startAngle: start,
                       endAngle: start + CGFloat.pi * 0.34, clockwise: false)
        }
        ctx.strokePath()
        let wordRect = CGRect(x: icon.maxX + rect.height * 0.08, y: rect.minY,
                              width: max(rect.maxX - icon.maxX - rect.height * 0.08, 1),
                              height: rect.height)
        let font = UIFont.systemFont(ofSize: rect.height * 0.34, weight: .semibold)
        let size = ("HONOR" as NSString).size(withAttributes: [.font: font])
        ("HONOR" as NSString).draw(at: CGPoint(x: wordRect.midX - size.width * 0.5,
                                               y: wordRect.midY - size.height * 0.5),
                                    withAttributes: [.font: font, .foregroundColor: UIColor.white])
    case .word(let text, let weight):
        let size = fittedFontSize(text, base: rect.height * 0.52,
                                  minimum: rect.height * 0.27,
                                  maxWidth: rect.width, weight: weight)
        centeredText(text, font: UIFont.systemFont(ofSize: size, weight: weight), color: .white)
    case .camera:
        centeredText("◉", font: UIFont.systemFont(ofSize: rect.height * 0.62,
                                                   weight: .semibold), color: .white)
    }
}
}

