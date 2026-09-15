//
//  AudioEffects.swift
//  Verto
//
//  Offline audio editing stage: playback speed with pitch preserved
//  (AVAudioUnitTimePitch), gain, fade in/out, and trim — rendered
//  faster than real time through AVAudioEngine's manual rendering mode
//  into a temporary float32 CAF, which then feeds the normal encoder.
//

import Foundation
import AVFoundation

struct AudioEffects {

    /// Render `source` (any file AVAudioFile can read: mp3, m4a, wav, aiff, caf)
    /// through the edit chain and return the temporary CAF that was written.
    /// The caller owns the returned file and deletes it when done.
    static func render(source: URL,
                       settings: ConversionSettings,
                       progress: @escaping @Sendable (Double) -> Void) throws -> URL {

        let file = try AVAudioFile(forReading: source)
        let format = file.processingFormat
        let sampleRate = format.sampleRate
        let channelCount = Int(format.channelCount)
        let totalFrames = file.length
        guard sampleRate > 0, totalFrames > 0, channelCount > 0 else {
            throw ConversionError.exportFailed("音频文件为空")
        }

        // Trim → schedule only the requested segment.
        let startFrame = min(max(0, AVAudioFramePosition((settings.trimStart ?? 0) * sampleRate)),
                             totalFrames)
        let requestedEnd = settings.trimEnd.map { AVAudioFramePosition($0 * sampleRate) } ?? totalFrames
        let endFrame = min(max(startFrame, requestedEnd), totalFrames)
        let segmentFrames = AVAudioFrameCount(endFrame - startFrame)
        guard segmentFrames > 0 else {
            throw ConversionError.exportFailed("裁剪区间为空")
        }

        let rate = min(max(settings.audioSpeed, 0.5), 2.0)

        // Engine graph: player → time-pitch → mixer, rendered offline.
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        let timePitch = AVAudioUnitTimePitch()
        timePitch.rate = Float(rate)
        engine.attach(player)
        engine.attach(timePitch)
        engine.connect(player, to: timePitch, format: format)
        engine.connect(timePitch, to: engine.mainMixerNode, format: format)

        let blockFrames: AVAudioFrameCount = 4096
        try engine.enableManualRenderingMode(.offline, format: format,
                                             maximumFrameCount: blockFrames)
        try engine.start()
        defer {
            player.stop()
            engine.stop()
        }
        player.scheduleSegment(file, startingFrame: startFrame,
                               frameCount: segmentFrames, at: nil,
                               completionHandler: nil)
        player.play()

        // Output bookkeeping: the time-pitch unit delays its output slightly,
        // so render (content + latency) frames and drop the silent head.
        let contentFrames = AVAudioFramePosition((Double(segmentFrames) / rate).rounded(.up))
        var skipRemaining = AVAudioFramePosition((timePitch.auAudioUnit.latency * sampleRate).rounded())
        let totalToRender = contentFrames + skipRemaining

        let gainLinear = Float(pow(10.0, settings.gainDB / 20.0))
        let outDuration = Double(contentFrames) / sampleRate
        let fadeIn = min(max(0, settings.fadeInSeconds), outDuration)
        let fadeOut = min(max(0, settings.fadeOutSeconds), outDuration)
        let shapesAmplitude = gainLinear != 1 || fadeIn > 0 || fadeOut > 0

        guard let buffer = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat,
                                            frameCapacity: blockFrames) else {
            throw ConversionError.exportFailed("无法分配音频缓冲区")
        }

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("verto-audiofx-\(UUID().uuidString).caf")
        let outFile = try AVAudioFile(forWriting: tempURL,
                                      settings: format.settings,
                                      commonFormat: .pcmFormatFloat32,
                                      interleaved: false)

        var renderedFrames: AVAudioFramePosition = 0
        var writtenFrames: AVAudioFramePosition = 0
        var stalledPasses = 0

        do {
            while renderedFrames < totalToRender {
                try Task.checkCancellation()
                let remaining = totalToRender - renderedFrames
                let framesThisPass = AVAudioFrameCount(min(AVAudioFramePosition(blockFrames), remaining))
                let status = try engine.renderOffline(framesThisPass, to: buffer)

                switch status {
                case .success:
                    let produced = AVAudioFramePosition(buffer.frameLength)
                    if produced == 0 {
                        stalledPasses += 1
                        guard stalledPasses < 1_000 else {
                            throw ConversionError.exportFailed("音频渲染停滞")
                        }
                        continue
                    }
                    stalledPasses = 0
                    renderedFrames += produced

                    // Drop the latency head, cap at the content length.
                    var offset: AVAudioFramePosition = 0
                    var frames = produced
                    if skipRemaining > 0 {
                        let drop = min(skipRemaining, frames)
                        offset = drop
                        frames -= drop
                        skipRemaining -= drop
                    }
                    frames = min(frames, contentFrames - writtenFrames)
                    guard frames > 0 else { continue }

                    compact(buffer, channelCount: channelCount,
                            offset: Int(offset), frames: Int(frames))
                    if shapesAmplitude {
                        applyEnvelope(buffer, channelCount: channelCount,
                                      startFrame: writtenFrames,
                                      sampleRate: sampleRate,
                                      gain: gainLinear,
                                      fadeIn: fadeIn, fadeOut: fadeOut,
                                      totalDuration: outDuration)
                    }
                    try outFile.write(from: buffer)
                    writtenFrames += frames
                    progress(min(1, Double(writtenFrames) / Double(max(1, contentFrames))))

                case .insufficientDataFromInputNode, .cannotDoInCurrentContext:
                    stalledPasses += 1
                    guard stalledPasses < 1_000 else {
                        throw ConversionError.exportFailed("音频渲染停滞")
                    }
                    continue

                case .error:
                    throw ConversionError.exportFailed("音频渲染失败")

                @unknown default:
                    throw ConversionError.exportFailed("音频渲染失败")
                }
            }
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            throw error
        }

        return tempURL
    }

    // MARK: - Buffer helpers

    /// Shift the wanted frames to the front of the buffer and shorten it.
    private static func compact(_ buffer: AVAudioPCMBuffer,
                                channelCount: Int, offset: Int, frames: Int) {
        guard let channels = buffer.floatChannelData else { return }
        if offset > 0 {
            for channel in 0..<channelCount {
                let base = channels[channel]
                // memmove: source and destination overlap.
                memmove(base, base + offset, frames * MemoryLayout<Float>.size)
            }
        }
        buffer.frameLength = AVAudioFrameCount(frames)
    }

    /// Multiply the buffer by gain and the fade envelope, sample-accurately.
    private static func applyEnvelope(_ buffer: AVAudioPCMBuffer,
                                      channelCount: Int,
                                      startFrame: AVAudioFramePosition,
                                      sampleRate: Double,
                                      gain: Float,
                                      fadeIn: Double, fadeOut: Double,
                                      totalDuration: Double) {
        guard let channels = buffer.floatChannelData else { return }
        let frames = Int(buffer.frameLength)
        for index in 0..<frames {
            let t = (Double(startFrame) + Double(index)) / sampleRate
            var envelope = gain
            if fadeIn > 0, t < fadeIn {
                envelope *= Float(max(0, t / fadeIn))
            }
            if fadeOut > 0 {
                let remaining = totalDuration - t
                if remaining < fadeOut {
                    envelope *= Float(max(0, remaining / fadeOut))
                }
            }
            if envelope != 1 {
                for channel in 0..<channelCount {
                    channels[channel][index] *= envelope
                }
            }
        }
    }
}
