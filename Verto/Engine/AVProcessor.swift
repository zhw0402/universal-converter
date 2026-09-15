//
//  AVProcessor.swift
//  Verto
//
//  Video container conversion, audio conversion and audio extraction.
//  Automatic sizing goes through Apple's export presets; explicit
//  bitrate / target-size requests go through the custom VideoTranscoder.
//

import Foundation
import AVFoundation

struct AVProcessor {

    static func convert(source: URL,
                        to format: OutputFormat,
                        settings: ConversionSettings,
                        outputDirectory: URL,
                        progress: @escaping @Sendable (Double) -> Void) async throws -> [URL] {

        let baseName = source.deletingPathExtension().lastPathComponent
        let destination = ConversionEngine.uniqueDestination(in: outputDirectory,
                                                             baseName: baseName,
                                                             fileExtension: format.fileExtension)

        switch format {
        case .mp4, .mov, .m4v:
            let fileType: AVFileType = (format == .mp4) ? .mp4 : (format == .mov) ? .mov : .m4v
            try await exportVideo(source: source, to: destination, fileType: fileType,
                                  settings: settings, progress: progress)

        case .m4a, .wav, .aiff, .caf:
            try await convertAudio(source: source, to: destination, format: format,
                                   settings: settings, progress: progress)

        default:
            throw ConversionError.unsupportedConversion
        }

        progress(1)
        return [destination]
    }

    // MARK: - Audio routing

    /// Audio output. Plain conversions stream straight through the
    /// reader→writer pipeline (with an optional trim). When speed, gain or
    /// fades are requested, an offline AVAudioEngine stage renders the edits
    /// first; video sources get their soundtrack extracted before that.
    private static func convertAudio(source: URL,
                                     to destination: URL,
                                     format: OutputFormat,
                                     settings: ConversionSettings,
                                     progress: @escaping @Sendable (Double) -> Void) async throws {

        var temporaries: [URL] = []
        defer {
            for url in temporaries { try? FileManager.default.removeItem(at: url) }
        }

        var encodeInput = source
        var encodeTrim = settings.trimRangeSeconds
        var encodeProgress = progress

        if settings.wantsAudioEffects {
            var effectsInput = source
            var effectsSettings = settings
            var effectsSpan: (Double, Double) = (0.0, 0.7)

            // AVAudioFile cannot open movie containers — extract the
            // soundtrack to PCM first (applying the trim right here).
            if !audioFileReadable(source) {
                let extracted = FileManager.default.temporaryDirectory
                    .appendingPathComponent("verto-extract-\(UUID().uuidString).wav")
                try await transcodeAudio(source: source, to: extracted, fileType: .wav,
                                         makeWriterSettings: { sampleRate, channels in
                                             [AVFormatIDKey: kAudioFormatLinearPCM,
                                              AVSampleRateKey: sampleRate,
                                              AVNumberOfChannelsKey: channels,
                                              AVLinearPCMBitDepthKey: 16,
                                              AVLinearPCMIsFloatKey: false,
                                              AVLinearPCMIsBigEndianKey: false,
                                              AVLinearPCMIsNonInterleaved: false]
                                         },
                                         readerBigEndian: false,
                                         trim: settings.trimRangeSeconds,
                                         progress: { p in progress(p * 0.3) })
                temporaries.append(extracted)
                effectsInput = extracted
                effectsSettings.trimStart = nil       // already applied
                effectsSettings.trimEnd = nil
                effectsSpan = (0.3, 0.4)
            }

            let (spanStart, spanWidth) = effectsSpan
            let rendered = try AudioEffects.render(source: effectsInput,
                                                   settings: effectsSettings,
                                                   progress: { p in progress(spanStart + p * spanWidth) })
            temporaries.append(rendered)
            encodeInput = rendered
            encodeTrim = nil                          // applied in the effects stage
            let encodeBase = spanStart + spanWidth
            encodeProgress = { p in progress(encodeBase + p * (1 - encodeBase)) }
        }

        switch format {
        case .m4a:
            try await transcodeAudio(source: encodeInput, to: destination, fileType: .m4a,
                                     makeWriterSettings: { sampleRate, channels in
                                         [AVFormatIDKey: kAudioFormatMPEG4AAC,
                                          AVSampleRateKey: min(sampleRate, 48_000),
                                          AVNumberOfChannelsKey: min(channels, 2),
                                          AVEncoderBitRateKey: settings.audioKbps * 1_000]
                                     },
                                     readerBigEndian: false,
                                     trim: encodeTrim,
                                     progress: encodeProgress)

        case .wav, .aiff, .caf:
            let fileType: AVFileType = (format == .wav) ? .wav : (format == .aiff) ? .aiff : .caf
            let bigEndian = (format == .aiff)
            try await transcodeAudio(source: encodeInput, to: destination, fileType: fileType,
                                     makeWriterSettings: { sampleRate, channels in
                                         [AVFormatIDKey: kAudioFormatLinearPCM,
                                          AVSampleRateKey: sampleRate,
                                          AVNumberOfChannelsKey: channels,
                                          AVLinearPCMBitDepthKey: 16,
                                          AVLinearPCMIsFloatKey: false,
                                          AVLinearPCMIsBigEndianKey: bigEndian,
                                          AVLinearPCMIsNonInterleaved: false]
                                     },
                                     readerBigEndian: bigEndian,
                                     trim: encodeTrim,
                                     progress: encodeProgress)

        default:
            throw ConversionError.unsupportedConversion
        }
    }

    private static func audioFileReadable(_ url: URL) -> Bool {
        (try? AVAudioFile(forReading: url)) != nil
    }

    // MARK: - Video routing

    private static func exportVideo(source: URL,
                                    to destination: URL,
                                    fileType: AVFileType,
                                    settings: ConversionSettings,
                                    progress: @escaping @Sendable (Double) -> Void) async throws {
        let trim = settings.trimRangeSeconds

        switch settings.videoSizing {
        case .auto:
            // Apple preset path: encoder chooses the bitrate for the resolution.
            try await exportWithPreset(AVURLAsset(url: source),
                                       to: destination,
                                       fileType: fileType,
                                       preset: settings.videoResolution.avPresetName,
                                       trim: trim,
                                       progress: progress)

        case .bitrate(let mbps):
            try await VideoTranscoder.transcode(source: source,
                                                to: destination,
                                                fileType: fileType,
                                                codec: settings.videoCodec,
                                                maxDimension: settings.videoResolution.maxDimension,
                                                videoBitrate: Int(mbps * 1_000_000),
                                                audioKbps: settings.audioKbps,
                                                trim: trim,
                                                progress: progress)

        case .targetSize(let megabytes):
            // Movavi-style: derive the video bitrate from the requested file
            // size — over the *trimmed* duration, so the number stays honest.
            let fullDuration = try await AVURLAsset(url: source).load(.duration).seconds
            var duration = fullDuration
            if let trim {
                let start = min(max(0, trim.start), fullDuration)
                let end = min(trim.end ?? fullDuration, fullDuration)
                duration = max(0, end - start)
            }
            guard duration > 0 else { throw ConversionError.exportFailed("时长未知") }
            let totalBits = megabytes * 1_000_000 * 8
            let audioBits = Double(settings.audioKbps) * 1_000 * duration
            let videoBitrate = max(150_000, Int((totalBits - audioBits) / duration * 0.97)) // 3% container overhead
            try await VideoTranscoder.transcode(source: source,
                                                to: destination,
                                                fileType: fileType,
                                                codec: settings.videoCodec,
                                                maxDimension: settings.videoResolution.maxDimension,
                                                videoBitrate: videoBitrate,
                                                audioKbps: settings.audioKbps,
                                                trim: trim,
                                                progress: progress)
        }
    }

    // MARK: - AVAssetExportSession (automatic sizing)

    private static func exportWithPreset(_ asset: AVAsset,
                                         to destination: URL,
                                         fileType: AVFileType,
                                         preset: String,
                                         trim: (start: Double, end: Double?)?,
                                         progress: @escaping @Sendable (Double) -> Void) async throws {

        guard let session = AVAssetExportSession(asset: asset, presetName: preset) else {
            throw ConversionError.exportFailed("该文件不支持所选的质量预设")
        }
        guard session.supportedFileTypes.contains(fileType) else {
            throw ConversionError.exportFailed("cannot write \(fileType.rawValue) from this source")
        }

        session.outputURL = destination
        session.outputFileType = fileType
        session.shouldOptimizeForNetworkUse = true

        if let trim {
            let duration = try await asset.load(.duration).seconds
            let start = min(max(0, trim.start), duration)
            let end = min(trim.end ?? duration, duration)
            guard end > start else { throw ConversionError.exportFailed("裁剪区间为空") }
            session.timeRange = CMTimeRange(
                start: CMTime(seconds: start, preferredTimescale: 600),
                end: CMTime(seconds: end, preferredTimescale: 600))
        }

        let sessionBox = SendableBox(session)
        let poller = Task {
            while !Task.isCancelled {
                progress(Double(sessionBox.value.progress))
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }
        defer { poller.cancel() }

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                sessionBox.value.exportAsynchronously {
                    switch sessionBox.value.status {
                    case .completed:
                        continuation.resume()
                    case .cancelled:
                        continuation.resume(throwing: CancellationError())
                    default:
                        let message = sessionBox.value.error?.localizedDescription ?? "未知错误"
                        continuation.resume(throwing: ConversionError.exportFailed(message))
                    }
                }
            }
        } onCancel: {
            sessionBox.value.cancelExport()
        }
    }

    // MARK: - Audio (PCM and AAC share one pipeline)

    private static func transcodeAudio(source: URL,
                                       to destination: URL,
                                       fileType: AVFileType,
                                       makeWriterSettings: (Double, UInt32) -> [String: Any],
                                       readerBigEndian: Bool,
                                       trim: (start: Double, end: Double?)? = nil,
                                       progress: @escaping @Sendable (Double) -> Void) async throws {

        let asset = AVURLAsset(url: source)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            throw ConversionError.noAudioTrack
        }
        let duration = try await asset.load(.duration).seconds

        // Trim window (defaults to the whole file). Immutable so the
        // progress closure can capture them from concurrent code.
        let rangeStart: Double
        let rangeDuration: Double
        if let trim {
            let start = min(max(0, trim.start), duration)
            let end = min(trim.end ?? duration, duration)
            guard end > start else { throw ConversionError.exportFailed("裁剪区间为空") }
            rangeStart = start
            rangeDuration = end - start
        } else {
            rangeStart = 0
            rangeDuration = duration
        }

        var sampleRate: Double = 44_100
        var channels: UInt32 = 2
        if let description = try await track.load(.formatDescriptions).first,
           let basic = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee {
            if basic.mSampleRate > 0 { sampleRate = basic.mSampleRate }
            if basic.mChannelsPerFrame > 0 { channels = basic.mChannelsPerFrame }
        }

        let readerSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: readerBigEndian,
            AVLinearPCMIsNonInterleaved: false
        ]

        let reader = try AVAssetReader(asset: asset)
        if trim != nil {
            reader.timeRange = CMTimeRange(
                start: CMTime(seconds: rangeStart, preferredTimescale: 600),
                duration: CMTime(seconds: rangeDuration, preferredTimescale: 600))
        }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: readerSettings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw ConversionError.exportFailed("无法读取音轨") }
        reader.add(output)

        let writer = try AVAssetWriter(outputURL: destination, fileType: fileType)
        let input = AVAssetWriterInput(mediaType: .audio,
                                       outputSettings: makeWriterSettings(sampleRate, channels))
        input.expectsMediaDataInRealTime = false
        guard writer.canAdd(input) else { throw ConversionError.exportFailed("无法写入音轨") }
        writer.add(input)

        guard reader.startReading() else {
            throw ConversionError.exportFailed(reader.error?.localizedDescription ?? "无法开始读取")
        }
        guard writer.startWriting() else {
            throw ConversionError.exportFailed(writer.error?.localizedDescription ?? "无法开始写入")
        }
        writer.startSession(atSourceTime: trim == nil
            ? .zero
            : CMTime(seconds: rangeStart, preferredTimescale: 600))

        let inputBox = SendableBox(input)
        let outputBox = SendableBox(output)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let queue = DispatchQueue(label: "app.verto.audio-transcode")
            nonisolated(unsafe) var finished = false   // only touched on the serial queue
            inputBox.value.requestMediaDataWhenReady(on: queue) {
                while inputBox.value.isReadyForMoreMediaData {
                    guard !finished else { return }
                    if let sampleBuffer = outputBox.value.copyNextSampleBuffer() {
                        if !inputBox.value.append(sampleBuffer) {
                            finished = true
                            inputBox.value.markAsFinished()
                            continuation.resume()
                            return
                        }
                        if rangeDuration > 0 {
                            let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
                            progress(min(max(0, time - rangeStart) / rangeDuration, 1))
                        }
                    } else {
                        finished = true
                        inputBox.value.markAsFinished()
                        continuation.resume()
                        return
                    }
                }
            }
        }

        if reader.status == .failed {
            throw ConversionError.exportFailed(reader.error?.localizedDescription ?? "读取错误")
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            writer.finishWriting { continuation.resume() }
        }
        if writer.status == .failed {
            throw ConversionError.exportFailed(writer.error?.localizedDescription ?? "写入错误")
        }
    }
}
