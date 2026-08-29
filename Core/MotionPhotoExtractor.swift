import Foundation

enum MotionPhotoExtractor {
    static func containsEmbeddedVideo(at url: URL) -> Bool {
        (try? videoOffset(in: url)) != nil
    }

    static func extract(from url: URL, to directory: URL) throws
        -> (photoURL: URL, videoURL: URL) {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        let offset = try videoOffset(in: data)
        let photoURL = directory.appendingPathComponent("motion-still.jpg")
        let videoURL = directory.appendingPathComponent("motion-video.mp4")
        try Data(data[..<offset]).write(to: photoURL, options: .atomic)
        try Data(data[offset...]).write(to: videoURL, options: .atomic)
        return (photoURL, videoURL)
    }

    private static func videoOffset(in url: URL) throws -> Int {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        return try videoOffset(in: data)
    }

    private static func videoOffset(in data: Data) throws -> Int {
        guard data.count > 16 else { throw WatermarkError.missingResource }
        let marker = Data([0x66, 0x74, 0x79, 0x70])
        var searchEnd = data.endIndex
        while searchEnd > 8,
              let range = data.range(of: marker, options: .backwards, in: 0..<searchEnd) {
            let start = range.lowerBound - 4
            if start >= 0, start + 12 <= data.count {
                let size = data[start..<start + 4].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
                if size >= 8, start + Int(size) <= data.count { return start }
            }
            searchEnd = range.lowerBound
        }
        throw WatermarkError.missingResource
    }
}

