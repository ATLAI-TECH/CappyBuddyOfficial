import AppKit
import AVFoundation
import Combine
import Foundation
import ImageIO
import UniformTypeIdentifiers
import UserNotifications

// MARK: - Editing options

/// Crop choices. Besides "off" and a free-drag rectangle, we offer a few
/// fixed aspect ratios (centered) for the common "make it square / vertical"
/// cases without forcing the user to nudge the box by hand.
enum CropPreset: String, CaseIterable, Identifiable {
    case off
    case custom          // free-drag rectangle
    case square          // 1:1
    case landscape16x9
    case portrait9x16
    case landscape4x3
    case portrait3x4

    var id: String { rawValue }

    var label: String {
        switch self {
        case .off:            return "Off"
        case .custom:         return "Custom (drag)"
        case .square:         return "Square · 1:1"
        case .landscape16x9:  return "Landscape · 16:9"
        case .portrait9x16:   return "Portrait · 9:16"
        case .landscape4x3:   return "Landscape · 4:3"
        case .portrait3x4:    return "Portrait · 3:4"
        }
    }

    var isCustom: Bool { self == .custom }

    /// width / height for the fixed-ratio cases; `nil` otherwise.
    var aspectRatio: CGFloat? {
        switch self {
        case .square:        return 1
        case .landscape16x9: return 16.0 / 9.0
        case .portrait9x16:  return 9.0 / 16.0
        case .landscape4x3:  return 4.0 / 3.0
        case .portrait3x4:   return 3.0 / 4.0
        case .off, .custom:  return nil
        }
    }
}

enum PlaybackSpeed: String, CaseIterable, Identifiable {
    case half, normal, oneHalf, double

    var id: String { rawValue }

    var rate: Double {
        switch self {
        case .half:    return 0.5
        case .normal:  return 1.0
        case .oneHalf: return 1.5
        case .double:  return 2.0
        }
    }

    var label: String {
        switch self {
        case .half:    return "0.5×"
        case .normal:  return "1×"
        case .oneHalf: return "1.5×"
        case .double:  return "2×"
        }
    }
}

/// What region of the frame to keep. `rect` is normalized to `[0, 1]` with
/// a top-left origin (the SwiftUI / CGImage convention).
enum CropSpec: Sendable {
    case aspect(CGFloat)
    case rect(CGRect)
}

// MARK: - Geometry helpers

/// The centered, normalized (`[0, 1]`, top-left origin) sub-rect of a frame
/// with the given pixel aspect ratio that matches the requested aspect.
func centeredNormalizedCropRect(aspect target: CGFloat, frameAspect: CGFloat) -> CGRect {
    guard target > 0, frameAspect > 0 else { return CGRect(x: 0, y: 0, width: 1, height: 1) }
    if frameAspect > target {
        let w = target / frameAspect
        return CGRect(x: (1 - w) / 2, y: 0, width: w, height: 1)
    } else {
        let h = frameAspect / target
        return CGRect(x: 0, y: (1 - h) / 2, width: 1, height: h)
    }
}

// MARK: - Editor view model

@MainActor
final class VideoEditorModel: ObservableObject {

    let player = AVPlayer()

    @Published private(set) var sourceURL: URL?
    /// Clip duration in seconds (0 until a video is loaded).
    @Published private(set) var duration: Double = 0
    /// Pixel size of the source video (after orientation), 0×0 until loaded.
    @Published private(set) var displaySize: CGSize = .zero

    @Published var trimStart: Double = 0
    @Published var trimEnd: Double = 0

    @Published var cropPreset: CropPreset = .off
    /// Free-drag crop region, normalized to `[0, 1]`, top-left origin.
    /// Only meaningful when `cropPreset == .custom`.
    @Published var customCrop: CGRect = CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8)
    @Published var muteAudio: Bool = false
    @Published var speed: PlaybackSpeed = .normal

    @Published private(set) var isLoading = false
    @Published private(set) var isExporting = false
    @Published private(set) var exportProgress: Double = 0
    @Published private(set) var loadError: String?

    /// Minimum length of the retained clip, in seconds.
    private let minClipLength: Double = 0.2

    private var boundaryObserver: Any?

    var hasVideo: Bool { sourceURL != nil }
    var trimmedDuration: Double { max(0, trimEnd - trimStart) }
    var displayAspect: CGFloat {
        displaySize.height > 0 ? displaySize.width / displaySize.height : 16.0 / 9.0
    }

    /// The crop region the editor is currently set to keep, normalized to
    /// `[0, 1]` (top-left origin) — used to draw the overlay. `nil` when no
    /// crop is active.
    var activeCropRect: CGRect? {
        switch cropPreset {
        case .off:    return nil
        case .custom: return customCrop
        default:
            guard let aspect = cropPreset.aspectRatio else { return nil }
            return centeredNormalizedCropRect(aspect: aspect, frameAspect: displayAspect)
        }
    }

    private var cropSpec: CropSpec? {
        switch cropPreset {
        case .off:    return nil
        case .custom:
            // Treat a near-full-frame box as "no crop".
            if customCrop.width > 0.985 && customCrop.height > 0.985 { return nil }
            return .rect(customCrop)
        default:
            guard let aspect = cropPreset.aspectRatio else { return nil }
            return .aspect(aspect)
        }
    }

    // MARK: Loading

    func load(url: URL) {
        isLoading = true
        loadError = nil
        let asset = AVURLAsset(url: url)
        Task { [weak self] in
            do {
                let duration = try await asset.load(.duration)
                let videoTracks = try await asset.loadTracks(withMediaType: .video)
                guard let videoTrack = videoTracks.first else {
                    throw EditorError.noVideoTrack
                }
                let (natSize, transform) = try await videoTrack.load(.naturalSize, .preferredTransform)
                let oriented = CGRect(origin: .zero, size: natSize).applying(transform)
                let displaySize = CGSize(width: abs(oriented.width), height: abs(oriented.height))
                let seconds = CMTimeGetSeconds(duration)

                guard let self else { return }
                let item = AVPlayerItem(asset: asset)
                self.player.replaceCurrentItem(with: item)
                self.sourceURL = url
                self.duration = seconds.isFinite ? seconds : 0
                self.displaySize = displaySize
                self.trimStart = 0
                self.trimEnd = self.duration
                self.cropPreset = .off
                self.customCrop = CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8)
                self.muteAudio = false
                self.speed = .normal
                self.isLoading = false
            } catch {
                guard let self else { return }
                self.isLoading = false
                self.loadError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                self.sourceURL = nil
            }
        }
    }

    // MARK: Playback helpers

    private var currentSeconds: Double {
        let t = CMTimeGetSeconds(player.currentTime())
        return t.isFinite ? t : 0
    }

    func togglePlayPause() {
        if player.timeControlStatus == .playing {
            player.pause()
        } else {
            if currentSeconds >= trimEnd - 0.05 || currentSeconds < trimStart {
                seek(to: trimStart)
            }
            player.play()
        }
    }

    /// Seek to the trim in-point and play through to the out-point, then stop.
    func previewSelection() {
        clearBoundaryObserver()
        seek(to: trimStart)
        let endTime = CMTime(seconds: trimEnd, preferredTimescale: 600)
        boundaryObserver = player.addBoundaryTimeObserver(
            forTimes: [NSValue(time: endTime)],
            queue: .main
        ) { [weak self] in
            // Observer fires on .main queue but the compiler can't see the
            // hop, so the call to MainActor-isolated members needs an
            // explicit assertion.
            MainActor.assumeIsolated {
                self?.player.pause()
                self?.clearBoundaryObserver()
            }
        }
        player.play()
    }

    func seek(to seconds: Double) {
        let clamped = min(max(seconds, 0), max(duration, 0))
        player.seek(to: CMTime(seconds: clamped, preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func setStartToPlayhead() {
        let s = min(currentSeconds, trimEnd - minClipLength)
        trimStart = max(0, s)
    }

    func setEndToPlayhead() {
        let s = max(currentSeconds, trimStart + minClipLength)
        trimEnd = min(duration, s)
    }

    func resetTrim() {
        trimStart = 0
        trimEnd = duration
    }

    private func clearBoundaryObserver() {
        if let boundaryObserver {
            player.removeTimeObserver(boundaryObserver)
            self.boundaryObserver = nil
        }
    }

    func cleanup() {
        clearBoundaryObserver()
        player.pause()
        player.replaceCurrentItem(with: nil)
    }

    // MARK: Export

    func export() {
        guard let sourceURL, !isExporting, !isLoading else { return }

        let format = VideoEditorPrefs.exportFormat
        let panel = NSSavePanel()
        panel.title = String(localized: "Export Video")
        panel.allowedContentTypes = [format.contentType]
        panel.canCreateDirectories = true
        let baseName = sourceURL.deletingPathExtension().lastPathComponent
        panel.nameFieldStringValue = "\(baseName) edited.\(format.fileExtension)"
        panel.directoryURL = sourceURL.deletingLastPathComponent()
        guard panel.runModal() == .OK, let outputURL = panel.url else { return }

        // NSSavePanel won't have removed an existing file at that path; both
        // export paths refuse to overwrite, so clear it ourselves first.
        try? FileManager.default.removeItem(at: outputURL)

        let startCM = CMTime(seconds: max(0, trimStart), preferredTimescale: 600)
        let endCM = CMTime(seconds: min(duration, max(trimEnd, trimStart + minClipLength)), preferredTimescale: 600)
        let request = VideoEditExportRequest(
            sourceURL: sourceURL,
            outputURL: outputURL,
            trimRange: CMTimeRange(start: startCM, duration: CMTimeSubtract(endCM, startCM)),
            crop: cropSpec,
            muteAudio: muteAudio,
            speed: speed.rate,
            avFileType: format.avFileType,
            presetName: format.isGIF ? nil : VideoEditorPrefs.exportQuality.presetName(hevc: format.usesHEVC)
        )

        isExporting = true
        exportProgress = 0
        let progress: @Sendable (Double) -> Void = { fraction in
            Task { @MainActor [weak self] in self?.exportProgress = max(0, min(1, fraction)) }
        }
        Task { [weak self] in
            do {
                if format.isGIF {
                    try await VideoEditExporter.exportGIF(request, onProgress: progress)
                } else {
                    try await VideoEditExporter.exportVideo(request, onProgress: progress)
                }
                guard let self else { return }
                self.exportProgress = 1
                self.isExporting = false
                VideoEditorNotifier.postExported(url: outputURL)
                if VideoEditorPrefs.revealInFinder {
                    NSWorkspace.shared.activateFileViewerSelecting([outputURL])
                }
            } catch {
                guard let self else { return }
                self.isExporting = false
                try? FileManager.default.removeItem(at: outputURL)
                let alert = NSAlert()
                alert.messageText = String(localized: "Export failed")
                alert.informativeText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                alert.alertStyle = .warning
                alert.runModal()
            }
        }
    }

    enum EditorError: LocalizedError {
        case noVideoTrack
        var errorDescription: String? {
            switch self {
            case .noVideoTrack: return String(localized: "This file doesn't contain a video track.")
            }
        }
    }
}

// MARK: - Export engine

struct VideoEditExportRequest: Sendable {
    let sourceURL: URL
    let outputURL: URL
    let trimRange: CMTimeRange
    let crop: CropSpec?
    let muteAudio: Bool
    /// Output speed multiplier (1.0 = unchanged, 2.0 = twice as fast).
    let speed: Double
    /// Container type for the `AVAssetExportSession` path; `nil` for GIF.
    let avFileType: AVFileType?
    let presetName: String?
}

enum VideoEditExporter {

    enum ExportError: LocalizedError {
        case noVideoTrack
        case cannotCompose
        case cannotCreateSession
        case gifWriteFailed
        case missingConfiguration
        var errorDescription: String? {
            switch self {
            case .noVideoTrack:          return String(localized: "The source file has no video track.")
            case .cannotCompose:         return String(localized: "Couldn't assemble the edit timeline.")
            case .cannotCreateSession:   return String(localized: "Couldn't start the export session.")
            case .gifWriteFailed:        return String(localized: "Couldn't write the GIF file.")
            case .missingConfiguration:  return String(localized: "Export configuration is incomplete.")
            }
        }
    }

    // MARK: Video (mov / mp4 / m4v)

    static func exportVideo(_ req: VideoEditExportRequest, onProgress: @escaping @Sendable (Double) -> Void) async throws {
        guard let fileType = req.avFileType, let presetName = req.presetName else {
            throw ExportError.missingConfiguration
        }
        let asset = AVURLAsset(url: req.sourceURL)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        guard let sourceVideo = videoTracks.first else { throw ExportError.noVideoTrack }
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        let (natSize, preferredTransform, nominalFrameRate) = try await sourceVideo.load(
            .naturalSize, .preferredTransform, .nominalFrameRate
        )

        // 1. Lay the trimmed segment onto a fresh composition.
        let composition = AVMutableComposition()
        guard let compVideo = composition.addMutableTrack(
            withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid
        ) else { throw ExportError.cannotCompose }
        try compVideo.insertTimeRange(req.trimRange, of: sourceVideo, at: .zero)
        compVideo.preferredTransform = preferredTransform

        var compAudio: AVMutableCompositionTrack?
        if !req.muteAudio, let sourceAudio = audioTracks.first {
            let track = composition.addMutableTrack(
                withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid
            )
            try track?.insertTimeRange(req.trimRange, of: sourceAudio, at: .zero)
            compAudio = track
        }

        // 2. Speed change — scale the inserted range to a new duration.
        if abs(req.speed - 1.0) > 0.001, req.speed > 0 {
            let inserted = CMTimeRange(start: .zero, duration: req.trimRange.duration)
            let scaled = CMTimeMultiplyByFloat64(inserted.duration, multiplier: 1.0 / req.speed)
            compVideo.scaleTimeRange(inserted, toDuration: scaled)
            compAudio?.scaleTimeRange(inserted, toDuration: scaled)
        }

        // 3. Crop — build a video composition that re-renders into the cropped box.
        var videoComposition: AVVideoComposition?
        if let crop = req.crop {
            let oriented = CGRect(origin: .zero, size: natSize).applying(preferredTransform)
            let orientedSize = CGSize(width: abs(oriented.width), height: abs(oriented.height))
            let box = pixelCropBox(crop, in: orientedSize)

            // Classic mutable API (macOS 10.9+) rather than the value-type
            // AVVideoComposition.Configuration builder, which is macOS 26 only —
            // keeping this on the established API lets the app deploy back to
            // macOS 15. Semantics are identical.
            let mutableVC = AVMutableVideoComposition()
            mutableVC.renderSize = box.size
            let fps = nominalFrameRate > 0 ? nominalFrameRate : 30
            mutableVC.frameDuration = CMTime(value: 1, timescale: CMTimeScale(max(1, fps.rounded())))

            let instruction = AVMutableVideoCompositionInstruction()
            instruction.timeRange = CMTimeRange(start: .zero, duration: composition.duration)

            let layerInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: compVideo)
            // Orient the raw buffer (preferredTransform), then shift the
            // crop's bottom-left corner to (0, 0) so it fills the render box.
            let transform = preferredTransform.concatenating(
                CGAffineTransform(translationX: -box.bottomLeft.x, y: -box.bottomLeft.y)
            )
            layerInstruction.setTransform(transform, at: .zero)

            instruction.layerInstructions = [layerInstruction]
            mutableVC.instructions = [instruction]
            videoComposition = mutableVC
        }

        // 4. Export with live progress.
        guard let session = AVAssetExportSession(asset: composition, presetName: presetName) else {
            throw ExportError.cannotCreateSession
        }
        session.videoComposition = videoComposition
        session.shouldOptimizeForNetworkUse = true

        async let exportFinished: Void = session.export(to: req.outputURL, as: fileType)
        for await state in session.states(updateInterval: 0.25) {
            if case .exporting(let progress) = state {
                onProgress(progress.fractionCompleted)
            }
        }
        try await exportFinished
    }

    // MARK: Animated GIF

    static func exportGIF(_ req: VideoEditExportRequest, onProgress: @escaping @Sendable (Double) -> Void) async throws {
        let asset = AVURLAsset(url: req.sourceURL)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = CMTime(value: 1, timescale: 60)
        generator.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 60)
        // Keep GIFs small — 480px longest side is plenty for a clip.
        generator.maximumSize = CGSize(width: 480, height: 480)

        let fps = 12.0
        let delay = 1.0 / fps
        let trimStart = CMTimeGetSeconds(req.trimRange.start)
        let trimDuration = CMTimeGetSeconds(req.trimRange.duration)
        let speed = max(req.speed, 0.01)
        let outDuration = max(trimDuration / speed, delay)
        // Cap the frame count so a long clip doesn't produce a monster file.
        let frameCount = max(1, min(Int((outDuration * fps).rounded()), 600))

        guard let destination = CGImageDestinationCreateWithURL(
            req.outputURL as CFURL, UTType.gif.identifier as CFString, frameCount, nil
        ) else { throw ExportError.gifWriteFailed }
        CGImageDestinationSetProperties(destination, [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]
        ] as CFDictionary)
        let frameProperties = [
            kCGImagePropertyGIFDictionary: [
                kCGImagePropertyGIFDelayTime: delay,
                kCGImagePropertyGIFUnclampedDelayTime: delay
            ]
        ] as CFDictionary

        var lastImage: CGImage?
        var wroteAny = false
        for i in 0..<frameCount {
            let srcSeconds = min(trimStart + (Double(i) / fps) * speed, trimStart + max(trimDuration - delay, 0))
            let time = CMTime(seconds: max(srcSeconds, 0), preferredTimescale: 600)
            let cgImage: CGImage
            do {
                cgImage = try await generator.image(at: time).image
                lastImage = cgImage
            } catch {
                guard let lastImage else { throw error }
                cgImage = lastImage
            }
            let frame = croppedCGImage(cgImage, crop: req.crop)
            CGImageDestinationAddImage(destination, frame, frameProperties)
            wroteAny = true
            onProgress(Double(i + 1) / Double(frameCount))
        }
        guard wroteAny, CGImageDestinationFinalize(destination) else { throw ExportError.gifWriteFailed }
    }

    // MARK: Crop math

    /// Resolves a `CropSpec` to an even-sized pixel rectangle inside a frame
    /// of `orientedSize`. Returns both the size and the bottom-left origin
    /// (Core Animation / `AVVideoComposition` coordinates).
    private static func pixelCropBox(_ spec: CropSpec, in orientedSize: CGSize) -> (size: CGSize, bottomLeft: CGPoint) {
        let W = orientedSize.width, H = orientedSize.height
        let topLeft = topLeftPixelRect(spec, frame: orientedSize)
        var x = max(0, topLeft.minX.rounded())
        var y = max(0, topLeft.minY.rounded())
        var w = (min(topLeft.width, W - x) / 2).rounded(.down) * 2
        var h = (min(topLeft.height, H - y) / 2).rounded(.down) * 2
        w = max(2, w); h = max(2, h)
        if x + w > W { x = max(0, W - w) }
        if y + h > H { y = max(0, H - h) }
        return (CGSize(width: w, height: h), CGPoint(x: x, y: max(0, H - y - h)))
    }

    /// Resolves a `CropSpec` to a pixel rectangle in top-left-origin
    /// coordinates (the `CGImage.cropping(to:)` convention).
    private static func topLeftPixelRect(_ spec: CropSpec, frame: CGSize) -> CGRect {
        switch spec {
        case .aspect(let ar):
            let norm = centeredNormalizedCropRect(aspect: ar, frameAspect: frame.width / max(frame.height, 1))
            return CGRect(x: norm.minX * frame.width, y: norm.minY * frame.height,
                          width: norm.width * frame.width, height: norm.height * frame.height)
        case .rect(let norm):
            return CGRect(x: norm.minX * frame.width, y: norm.minY * frame.height,
                          width: norm.width * frame.width, height: norm.height * frame.height)
        }
    }

    private static func croppedCGImage(_ image: CGImage, crop: CropSpec?) -> CGImage {
        guard let crop else { return image }
        let frame = CGSize(width: image.width, height: image.height)
        let rect = topLeftPixelRect(crop, frame: frame).integral
            .intersection(CGRect(x: 0, y: 0, width: frame.width, height: frame.height))
        guard !rect.isNull, rect.width >= 1, rect.height >= 1,
              let cropped = image.cropping(to: rect) else { return image }
        return cropped
    }
}

// MARK: - Notifications

enum VideoEditorNotifier {
    static func postExported(url: URL) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        let content = UNMutableNotificationContent()
        content.title = String(localized: "Video exported")
        content.body = url.lastPathComponent
        content.userInfo = ["path": url.path]
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        center.add(request, withCompletionHandler: nil)
    }
}
