//
//  VideoTranscoder.swift
//  Verto
//
//  Custom AVAssetReader → AVAssetWriter pipeline used when the user asks
//  for an explicit bitrate or a target file size. Gives Verto real
//  Movavi-style size control instead of fixed presets.
//

import Foundation
import AVFoundation

struct VideoTranscoder {

    /// Re-encode `source` with an explicit average video bitrate.
    static func transcode(source: URL,
                          to destination: URL,
                          fileType: AVFileType,
                          codec: VideoCodec,
                          maxDimension: CGFloat?,
                          videoBitrate: Int,
                          audioKbps: Int,
                          trim: (start: Double, end: Double?)? = nil,
                          progress: @escaping @Sendable (Double) -> Void) async throws {

        let asset = AVURLAsset(url: source)
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw ConversionError.exportFailed("该文件没有视频轨道")
        }
        let audioTrack = try await asset.loadTracks(withMediaType: .audio).first
        let duration = try await asset.load(.duration).seconds
        let (naturalSize, preferredTransform, nominalFrameRate) =
            try await videoTrack.load(.naturalSize, .preferredTransform, .nominalFrameRate)

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

        // Output dimensions: keep aspect ratio, cap the long edge, force even numbers.
        var width = abs(naturalSize.width)
        var height = abs(naturalSize.height)
        if let maxDimension, max(width, height) > maxDimension, max(width, height) > 0 {
            let scale = maxDimension / max(width, height)
            width *= scale
            height *= scale
        }
        var w = max(2, Int(width.rounded())); w -= w % 2
        var h = max(2, Int(height.rounded())); h -= h % 2

        let clampedBitrate = min(max(videoBitrate, 150_000), 80_000_000)
        _ = nominalFrameRate // reserved for future frame-rate control

        let reader = try AVAssetReader(asset: asset)
        if trim != nil {
            reader.timeRange = CMTimeRange(
                start: CMTime(seconds: rangeStart, preferredTimescale: 600),
                duration: CMTime(seconds: rangeDuration, preferredTimescale: 600))
        }
        let writer = try AVAssetWriter(outputURL: destination, fileType: fileType)

        // Video leg: decode to pixel buffers, re-encode at the requested bitrate.
        let videoOutput = AVAssetReaderTrackOutput(
            track: videoTrack,
            outputSettings: [kCVPixelBufferPixelFormatTypeKey as String:
                                kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange])
        videoOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(videoOutput) else { throw ConversionError.exportFailed("无法读取视频轨道") }
        reader.add(videoOutput)

        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: codec.avCodecType,
            AVVideoWidthKey: w,
            AVVideoHeightKey: h,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: clampedBitrate]
        ])
        videoInput.expectsMediaDataInRealTime = false
        videoInput.transform = preferredTransform   // keep rotation without re-rendering pixels
        guard writer.canAdd(videoInput) else { throw ConversionError.exportFailed("无法编码视频") }
        writer.add(videoInput)

        // Audio leg: decode to PCM, re-encode as AAC at the chosen bitrate.
        var audioPair: (AVAssetReaderTrackOutput, AVAssetWriterInput)?
        if let audioTrack {
            var sampleRate: Double = 44_100
            var channels: UInt32 = 2
            if let description = try await audioTrack.load(.formatDescriptions).first,
               let basic = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee {
                if basic.mSampleRate > 0 { sampleRate = basic.mSampleRate }
                if basic.mChannelsPerFrame > 0 { channels = basic.mChannelsPerFrame }
            }
            let audioOutput = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false
            ])
            audioOutput.alwaysCopiesSampleData = false
            let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: min(sampleRate, 48_000),
                AVNumberOfChannelsKey: min(channels, 2),
                AVEncoderBitRateKey: audioKbps * 1_000
            ])
            audioInput.expectsMediaDataInRealTime = false
            if reader.canAdd(audioOutput), writer.canAdd(audioInput) {
                reader.add(audioOutput)
                writer.add(audioInput)
                audioPair = (audioOutput, audioInput)
            }
        }

        guard reader.startReading() else {
            throw ConversionError.exportFailed(reader.error?.localizedDescription ?? "无法开始读取")
        }
        guard writer.startWriting() else {
            throw ConversionError.exportFailed(writer.error?.localizedDescription ?? "无法开始写入")
        }
        writer.startSession(atSourceTime: trim == nil
            ? .zero
            : CMTime(seconds: rangeStart, preferredTimescale: 600))

        let readerBox = SendableBox(reader)
        try await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let coordinator = DispatchGroup()
                pump(from: videoOutput, to: videoInput,
                     queueLabel: "app.verto.video-encode", group: coordinator) { seconds in
                    if rangeDuration > 0 {
                        progress(min(max(0, seconds - rangeStart) / rangeDuration, 0.99))
                    }
                }
                if let (audioOutput, audioInput) = audioPair {
                    pump(from: audioOutput, to: audioInput,
                         queueLabel: "app.verto.audio-encode", group: coordinator, onTime: nil)
                }
                coordinator.notify(queue: DispatchQueue(label: "app.verto.encode-done")) {
                    continuation.resume()
                }
            }

            if Task.isCancelled || reader.status == .cancelled {
                writer.cancelWriting()
                try? FileManager.default.removeItem(at: destination)
                throw CancellationError()
            }
            if reader.status == .failed {
                writer.cancelWriting()
                throw ConversionError.exportFailed(reader.error?.localizedDescription ?? "读取错误")
            }
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                writer.finishWriting { continuation.resume() }
            }
            if writer.status == .failed {
                throw ConversionError.exportFailed(writer.error?.localizedDescription ?? "编码错误")
            }
        } onCancel: {
            readerBox.value.cancelReading()
        }
    }

    /// Copy every sample buffer from a reader output into a writer input.
    private static func pump(from output: AVAssetReaderTrackOutput,
                             to input: AVAssetWriterInput,
                             queueLabel: String,
                             group: DispatchGroup,
                             onTime: (@Sendable (Double) -> Void)?) {
        group.enter()
        let inputBox = SendableBox(input)
        let outputBox = SendableBox(output)
        nonisolated(unsafe) var finished = false   // only touched on the serial queue
        input.requestMediaDataWhenReady(on: DispatchQueue(label: queueLabel)) {
            while inputBox.value.isReadyForMoreMediaData {
                guard !finished else { return }
                if let buffer = outputBox.value.copyNextSampleBuffer() {
                    if !inputBox.value.append(buffer) {
                        finished = true
                        inputBox.value.markAsFinished()
                        group.leave()
                        return
                    }
                    onTime?(CMSampleBufferGetPresentationTimeStamp(buffer).seconds)
                } else {
                    finished = true
                    inputBox.value.markAsFinished()
                    group.leave()
                    return
                }
            }
        }
    }
}
