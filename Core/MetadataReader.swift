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
        if let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            let make = (tiff[kCGImagePropertyTIFFMake] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let model = (tiff[kCGImagePropertyTIFFModel] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let model, !model.isEmpty {
                value.device = [make, model].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
            }
        }
        if let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] {
            var parts: [String] = []
            if let focal35 = exif[kCGImagePropertyExifFocalLenIn35mmFilm] as? NSNumber {
                parts.append("\(focal35.intValue)mm")
            } else if let focal = exif[kCGImagePropertyExifFocalLength] as? NSNumber {
                parts.append(String(format: "%.1fmm", focal.doubleValue))
            }
            if let aperture = exif[kCGImagePropertyExifFNumber] as? NSNumber {
                parts.append(String(format: "F%.2f", aperture.doubleValue))
            }
            if let exposure = exif[kCGImagePropertyExifExposureTime] as? NSNumber {
                let seconds = exposure.doubleValue
                parts.append(seconds < 1 ? "1/\(max(Int((1 / seconds).rounded()), 1))s" : String(format: "%.1fs", seconds))
            }
            if let iso = (exif[kCGImagePropertyExifISOSpeedRatings] as? [NSNumber])?.first {
                parts.append("ISO\(iso.intValue)")
            } else if let iso = exif["PhotographicSensitivity" as CFString] as? NSNumber {
                parts.append("ISO\(iso.intValue)")
            }
            if !parts.isEmpty { value.exposure = parts.joined(separator: "  ") }
        }
        return value
    }
}

