//
//  LivePhotoAssembler.swift
//  Lively
//
//  Turns a plain still + video file into a pair that Photos recognizes as a
//  single Live Photo. The trick is a shared UUID: the still carries it in its
//  MakerApple EXIF dictionary (key "17"), the video carries it as the
//  com.apple.quicktime.content.identifier asset-level metadata item plus a
//  timed still-image-time metadata track. Video and audio samples are copied
//  through untouched (passthrough), so assembly is fast and lossless.
//

import Foundation
import AVFoundation
import CoreMedia
import ImageIO

// MARK: - AssemblerError

/// Failures while writing the paired still or video.
enum AssemblerError: LocalizedError {
    /// The still image could not be read or rewritten with pairing metadata.
    case photoWriteFailed
    /// The video could not be remuxed with pairing metadata; the associated
    /// value is a short human-readable reason.
    case videoWriteFailed(String)

    var errorDescription: String? {
        switch self {
        case .photoWriteFailed:
            return "Couldn't prepare the Live Photo still image."
        case .videoWriteFailed(let reason):
            return "Couldn't prepare the Live Photo video. \(reason)"
        }
    }
}

// MARK: - LivePhotoAssembler

/// Writes the metadata that links a still and a video into a Live Photo pair.
final class LivePhotoAssembler: Sendable {

    init() {}

    // MARK: - Pairing

    /// Produces a still/video pair sharing a fresh UUID content identifier.
    ///
    /// - Parameters:
    ///   - photoURL: The (already filtered) still to tag.
    ///   - metadataSourceURL: Optional original still whose image properties
    ///     (EXIF, TIFF, GPS…) should be carried over onto the output still.
    ///     When `nil`, the properties of `photoURL` itself are used.
    ///   - videoURL: The (already processed) movie to remux with pairing
    ///     metadata.
    ///   - directory: Destination directory for both outputs.
    /// - Returns: URLs of the paired still and movie, plus the identifier
    ///   they share. Outputs are named `LivelyPair-<identifier>.<heic|jpg>`
    ///   and `LivelyPair-<identifier>.mov`.
    func makePair(photoURL: URL,
                  metadataSourceURL: URL?,
                  videoURL: URL,
                  in directory: URL) async throws -> (photoURL: URL, videoURL: URL, identifier: String) {
        let identifier = UUID().uuidString

        let stillExtension = photoURL.pathExtension.lowercased() == "heic" ? "heic" : "jpg"
        let pairedPhotoURL = directory.appendingPathComponent("LivelyPair-\(identifier).\(stillExtension)")
        let pairedVideoURL = directory.appendingPathComponent("LivelyPair-\(identifier).mov")

        try writeStill(from: photoURL,
                       metadataSourceURL: metadataSourceURL,
                       identifier: identifier,
                       to: pairedPhotoURL)
        try await writeVideo(from: videoURL,
                             identifier: identifier,
                             to: pairedVideoURL)

        return (pairedPhotoURL, pairedVideoURL, identifier)
    }

    // MARK: - Still writing

    /// Copies the still image, injecting the content identifier into the
    /// MakerApple dictionary under key "17" — the marker Photos uses to match
    /// a still with its paired video.
    private func writeStill(from photoURL: URL,
                            metadataSourceURL: URL?,
                            identifier: String,
                            to outputURL: URL) throws {
        guard let source = CGImageSourceCreateWithURL(photoURL as CFURL, nil),
              CGImageSourceGetCount(source) > 0,
              let sourceType = CGImageSourceGetType(source) else {
            throw AssemblerError.photoWriteFailed
        }

        // Prefer the original photo's properties (EXIF, orientation, GPS…)
        // when a metadata source is supplied; fall back to the still's own.
        var properties: [CFString: Any] = [:]
        if let metadataSourceURL,
           let metadataSource = CGImageSourceCreateWithURL(metadataSourceURL as CFURL, nil),
           CGImageSourceGetCount(metadataSource) > 0,
           let carried = CGImageSourceCopyPropertiesAtIndex(metadataSource, 0, nil) as? [CFString: Any] {
            properties = carried
        } else if let own = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {
            properties = own
        }

        // The rendered pixels are already upright and may have been scaled.
        // Preserve capture metadata while removing geometry fields that would
        // rotate the output again or describe the original dimensions.
        properties[kCGImagePropertyOrientation] = 1
        properties.removeValue(forKey: kCGImagePropertyPixelWidth)
        properties.removeValue(forKey: kCGImagePropertyPixelHeight)
        if var exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] {
            exif.removeValue(forKey: kCGImagePropertyExifPixelXDimension)
            exif.removeValue(forKey: kCGImagePropertyExifPixelYDimension)
            properties[kCGImagePropertyExifDictionary] = exif
        }

        // Merge the pairing identifier into MakerApple (preserving any
        // existing MakerApple entries).
        var makerApple = properties[kCGImagePropertyMakerAppleDictionary] as? [String: Any] ?? [:]
        makerApple["17"] = identifier
        properties[kCGImagePropertyMakerAppleDictionary] = makerApple

        try? FileManager.default.removeItem(at: outputURL)
        guard let destination = CGImageDestinationCreateWithURL(outputURL as CFURL, sourceType, 1, nil) else {
            throw AssemblerError.photoWriteFailed
        }
        CGImageDestinationAddImageFromSource(destination, source, 0, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw AssemblerError.photoWriteFailed
        }
    }

    // MARK: - Video writing

    /// Remuxes the movie with (a) an asset-level content-identifier metadata
    /// item and (b) a timed metadata track carrying the still-image-time
    /// marker. Video and audio samples are copied through without re-encoding.
    private func writeVideo(from videoURL: URL,
                            identifier: String,
                            to outputURL: URL) async throws {
        let asset = AVURLAsset(url: videoURL)

        let duration: CMTime
        let videoTracks: [AVAssetTrack]
        let audioTracks: [AVAssetTrack]
        do {
            duration = try await asset.load(.duration)
            videoTracks = try await asset.loadTracks(withMediaType: .video)
            audioTracks = try await asset.loadTracks(withMediaType: .audio)
        } catch {
            throw AssemblerError.videoWriteFailed("The processed movie couldn't be read.")
        }
        guard let videoTrack = videoTracks.first else {
            throw AssemblerError.videoWriteFailed("The processed movie has no video track.")
        }

        try? FileManager.default.removeItem(at: outputURL)

        let reader: AVAssetReader
        let writer: AVAssetWriter
        do {
            reader = try AVAssetReader(asset: asset)
            writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)
        } catch {
            throw AssemblerError.videoWriteFailed(error.localizedDescription)
        }

        // Asset-level pairing identifier.
        writer.metadata = [Self.contentIdentifierItem(identifier)]

        // Video passthrough.
        let videoOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: nil)
        videoOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(videoOutput) else {
            throw AssemblerError.videoWriteFailed("The video track can't be read for copying.")
        }
        reader.add(videoOutput)

        let videoFormatHint = try? await videoTrack.load(.formatDescriptions).first
        let videoInput = AVAssetWriterInput(mediaType: .video,
                                            outputSettings: nil,
                                            sourceFormatHint: videoFormatHint ?? nil)
        videoInput.expectsMediaDataInRealTime = false
        if let transform = try? await videoTrack.load(.preferredTransform) {
            videoInput.transform = transform
        }
        guard writer.canAdd(videoInput) else {
            throw AssemblerError.videoWriteFailed("The video track can't be written.")
        }
        writer.add(videoInput)

        // Audio passthrough (optional).
        var audioPair: (output: AVAssetReaderTrackOutput, input: AVAssetWriterInput)?
        if let audioTrack = audioTracks.first {
            let audioOutput = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: nil)
            audioOutput.alwaysCopiesSampleData = false
            let audioFormatHint = try? await audioTrack.load(.formatDescriptions).first
            let audioInput = AVAssetWriterInput(mediaType: .audio,
                                               outputSettings: nil,
                                               sourceFormatHint: audioFormatHint ?? nil)
            audioInput.expectsMediaDataInRealTime = false
            if reader.canAdd(audioOutput), writer.canAdd(audioInput) {
                reader.add(audioOutput)
                writer.add(audioInput)
                audioPair = (audioOutput, audioInput)
            }
        }

        // Timed still-image-time metadata track.
        let adaptor = try Self.makeStillImageTimeAdaptor()
        guard writer.canAdd(adaptor.assetWriterInput) else {
            throw AssemblerError.videoWriteFailed("The pairing metadata track can't be written.")
        }
        writer.add(adaptor.assetWriterInput)

        // Start the transfer.
        guard reader.startReading() else {
            throw AssemblerError.videoWriteFailed(reader.error?.localizedDescription ?? "Reading failed to start.")
        }
        guard writer.startWriting() else {
            reader.cancelReading()
            throw AssemblerError.videoWriteFailed(writer.error?.localizedDescription ?? "Writing failed to start.")
        }
        writer.startSession(atSourceTime: .zero)

        // One still-image-time sample at the midpoint of the clip tells
        // Photos which video frame corresponds to the still.
        let midpoint = CMTimeMinimum(CMTimeMultiplyByRatio(duration, multiplier: 1, divisor: 2), duration)
        let stillTimeRange = CMTimeRange(start: midpoint, duration: CMTime(value: 1, timescale: 30))
        let group = AVTimedMetadataGroup(items: [Self.stillImageTimeItem()], timeRange: stillTimeRange)
        guard adaptor.append(group) else {
            reader.cancelReading()
            writer.cancelWriting()
            throw AssemblerError.videoWriteFailed(writer.error?.localizedDescription ?? "The pairing marker couldn't be written.")
        }
        adaptor.assetWriterInput.markAsFinished()

        // Copy media samples; both tracks drain concurrently so the reader
        // never has to buffer one whole track while the other is consumed.
        await withTaskGroup(of: Void.self) { taskGroup in
            taskGroup.addTask {
                await self.copySamples(from: videoOutput,
                                       to: videoInput,
                                       queueLabel: "com.lively.assembler.video")
            }
            if let audioPair {
                taskGroup.addTask {
                    await self.copySamples(from: audioPair.output,
                                           to: audioPair.input,
                                           queueLabel: "com.lively.assembler.audio")
                }
            }
        }

        if reader.status == .failed {
            writer.cancelWriting()
            throw AssemblerError.videoWriteFailed(reader.error?.localizedDescription ?? "Reading the movie failed.")
        }

        await writer.finishWriting()
        guard writer.status == .completed else {
            throw AssemblerError.videoWriteFailed(writer.error?.localizedDescription ?? "Finishing the movie failed.")
        }
    }

    // MARK: - Sample copying

    /// Pulls sample buffers from `output` and appends them to `input` on a
    /// dedicated serial queue, resuming the continuation exactly once when
    /// the track is exhausted or an append fails (the writer records the
    /// failure; callers inspect `writer.status` afterwards).
    private func copySamples(from output: AVAssetReaderOutput,
                             to input: AVAssetWriterInput,
                             queueLabel: String) async {
        let queue = DispatchQueue(label: queueLabel)
        var finished = false
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            input.requestMediaDataWhenReady(on: queue) {
                guard !finished else { return }
                while input.isReadyForMoreMediaData {
                    guard let sample = output.copyNextSampleBuffer() else {
                        finished = true
                        input.markAsFinished()
                        continuation.resume()
                        return
                    }
                    guard input.append(sample) else {
                        finished = true
                        input.markAsFinished()
                        continuation.resume()
                        return
                    }
                }
            }
        }
    }

    // MARK: - Metadata items

    /// The asset-level identifier item that names this Live Photo pair.
    private static func contentIdentifierItem(_ identifier: String) -> AVMetadataItem {
        let item = AVMutableMetadataItem()
        item.keySpace = .quickTimeMetadata
        item.key = "com.apple.quicktime.content.identifier" as NSString
        item.identifier = AVMetadataIdentifier("mdta/com.apple.quicktime.content.identifier")
        item.dataType = kCMMetadataBaseDataType_UTF8 as String
        item.value = identifier as NSString
        return item
    }

    /// The timed marker Photos reads to find the still frame in the video.
    private static func stillImageTimeItem() -> AVMetadataItem {
        let item = AVMutableMetadataItem()
        item.keySpace = .quickTimeMetadata
        item.key = "com.apple.quicktime.still-image-time" as NSString
        item.identifier = AVMetadataIdentifier("mdta/com.apple.quicktime.still-image-time")
        item.dataType = "com.apple.metadata.datatype.int8"
        item.value = NSNumber(value: Int8(0))
        return item
    }

    /// Builds the metadata writer input + adaptor whose format description is
    /// created from metadata specifications for the still-image-time key.
    private static func makeStillImageTimeAdaptor() throws -> AVAssetWriterInputMetadataAdaptor {
        let specification: [CFString: Any] = [
            kCMMetadataFormatDescriptionMetadataSpecificationKey_Identifier:
                "mdta/com.apple.quicktime.still-image-time",
            kCMMetadataFormatDescriptionMetadataSpecificationKey_DataType:
                "com.apple.metadata.datatype.int8"
        ]
        var formatDescription: CMMetadataFormatDescription?
        let status = CMMetadataFormatDescriptionCreateWithMetadataSpecifications(
            allocator: kCFAllocatorDefault,
            metadataType: kCMMetadataFormatType_Boxed,
            metadataSpecifications: [specification] as CFArray,
            formatDescriptionOut: &formatDescription
        )
        guard status == noErr, let formatDescription else {
            throw AssemblerError.videoWriteFailed("The pairing metadata format couldn't be created.")
        }
        let input = AVAssetWriterInput(mediaType: .metadata,
                                       outputSettings: nil,
                                       sourceFormatHint: formatDescription)
        input.expectsMediaDataInRealTime = false
        return AVAssetWriterInputMetadataAdaptor(assetWriterInput: input)
    }
}

