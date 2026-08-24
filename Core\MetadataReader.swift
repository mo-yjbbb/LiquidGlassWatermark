import Photos
import ImageIO

enum MetadataReader {
    static func read(asset: PHAsset, input: PHContentEditingInput?) -> WatermarkMetadata {
        var value = WatermarkMetadata()
        if let date = asset.creationDate {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy.MM.dd HH:mm:ss"
            value.date = formatter.string(from: date)
        }
        if let location = asset.location {
            value.location = String(format: "%.5f°, %.5f°", location.coordinate.latitude, location.coordinate.longitude)
        }
        guard let url = input?.fullSizeImageURL,
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            return value
        }
        if let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any],
           let model = tiff[kCGImagePropertyTIFFModel] as? String {
            value.device = model
        }
        if let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] {
            var parts: [String] = []
            if let focal = exif[kCGImagePropertyExifFocalLength] as? NSNumber { parts.append("\(focal.intValue)mm") }
            if let aperture = exif[kCGImagePropertyExifFNumber] as? NSNumber { parts.append(String(format: "F%.2g", aperture.doubleValue)) }
            if let exposure = exif[kCGImagePropertyExifExposureTime] as? NSNumber {
                let seconds = exposure.doubleValue
                parts.append(seconds < 1 ? "1/\(max(Int((1 / seconds).rounded()), 1))s" : String(format: "%.1fs", seconds))
            }
            if let iso = (exif[kCGImagePropertyExifISOSpeedRatings] as? [NSNumber])?.first { parts.append("ISO\(iso.intValue)") }
            if !parts.isEmpty { value.exposure = parts.joined(separator: "  ") }
        }
        return value
    }
}

