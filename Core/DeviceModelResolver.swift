import Foundation

enum DeviceModelResolver {
    // Honor commonly writes an internal regulatory model into TIFF/EXIF.
    // Keep this exact-match table intentionally conservative: an unknown
    // identifier must remain visible rather than being guessed incorrectly.
    private static let honorModels: [String: String] = [
        "AAK-AN00": "HONOR WIN RT"
    ]

    static func displayName(make: String?, model: String) -> String {
        let cleanModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanMake = make?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let key = cleanModel.uppercased()

        if isHonor(make: cleanMake, model: cleanModel),
           let marketingName = honorModels[key] {
            return marketingName
        }
        if cleanModel.lowercased().hasPrefix("apple ") {
            return String(cleanModel.dropFirst("Apple ".count))
        }
        if cleanMake.caseInsensitiveCompare("Apple") == .orderedSame {
            return cleanModel
        }
        if !cleanMake.isEmpty,
           !cleanModel.lowercased().hasPrefix(cleanMake.lowercased()) {
            return "\(cleanMake) \(cleanModel)"
        }
        return cleanModel
    }

    private static func isHonor(make: String, model: String) -> Bool {
        let combined = "\(make) \(model)".lowercased()
        return combined.contains("honor") || combined.contains("荣耀") ||
            honorModels[model.uppercased()] != nil
    }
}
