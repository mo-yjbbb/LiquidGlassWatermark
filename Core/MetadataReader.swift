import Photos
import ImageIO

enum MetadataReader {
    static func read(asset: PHAsset?, imageURL: URL) -> WatermarkMetadata {
        var value = WatermarkMetadata()
        if let date = asset?.creationDate {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy.MM.dd HH:mm:ss"
            value.date = formatter.string(from: date)
        }
        if let location = asset?.location {
            value.location = coordinate(location.coordinate.latitude, positive: "N", negative: "S")
                + "  "
                + coordinate(location.coordinate.longitude, positive: "E", negative: "W")
        }
        guard let source = CGImageSourceCreateWithURL(imageURL as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            return value
        }
        if value.date.isEmpty,
           let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any],
           let text = exif[kCGImagePropertyExifDateTimeOriginal] as? String {
            let input = DateFormatter()
            input.locale = Locale(identifier: "en_US_POSIX")
            input.dateFormat = "yyyy:MM:dd HH:mm:ss"
            if let date = input.date(from: text) {
                let output = DateFormatter()
                output.dateFormat = "yyyy.MM.dd HH:mm:ss"
                value.date = output.string(from: date)
            }
        }
        if value.location.isEmpty,
           let gps = properties[kCGImagePropertyGPSDictionary] as? [CFString: Any],
           let latitude = gps[kCGImagePropertyGPSLatitude] as? NSNumber,
           let longitude = gps[kCGImagePropertyGPSLongitude] as? NSNumber {
            let latRef = (gps[kCGImagePropertyGPSLatitudeRef] as? String) ?? "N"
            let lonRef = (gps[kCGImagePropertyGPSLongitudeRef] as? String) ?? "E"
            let lat = latitude.doubleValue * (latRef.uppercased() == "S" ? -1 : 1)
            let lon = longitude.doubleValue * (lonRef.uppercased() == "W" ? -1 : 1)
            value.location = coordinate(lat, positive: "N", negative: "S")
                + "  " + coordinate(lon, positive: "E", negative: "W")
        }
        if let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            let make = (tiff[kCGImagePropertyTIFFMake] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let model = (tiff[kCGImagePropertyTIFFModel] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let model, !model.isEmpty {
                value.device = DeviceModelResolver.displayName(make: make, model: model)
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

    private static func coordinate(_ value: Double, positive: String, negative: String) -> String {
        let absolute = abs(value)
        let degrees = Int(absolute)
        let minutesValue = (absolute - Double(degrees)) * 60
        let minutes = Int(minutesValue)
        var seconds = Int(((minutesValue - Double(minutes)) * 60).rounded())
        var adjustedMinutes = minutes
        var adjustedDegrees = degrees
        if seconds == 60 {
            seconds = 0
            adjustedMinutes += 1
        }
        if adjustedMinutes == 60 {
            adjustedMinutes = 0
            adjustedDegrees += 1
        }
        return "\(adjustedDegrees)°\(adjustedMinutes)'\(seconds)\"\(value >= 0 ? positive : negative)"
    }
}
