//
//  JobOptionsView.swift
//  Verto
//
//  Per-file tuning. Beyond quality and sizing, 1.1 adds real editing:
//  PDF rotation / page ranges / margin trim / per-file DPI, image
//  rotation, audio speed (pitch preserved) / gain / fades, and start–end
//  trim for both audio and video.
//

import SwiftUI

struct JobOptionsView: View {
    @ObservedObject var job: ConversionJob

    private enum SizingMode: String, CaseIterable, Identifiable {
        case auto = "自动"
        case bitrate = "码率"
        case target = "目标体积"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 7) {
                Text("$")
                    .font(Theme.mono(13, .semibold))
                    .foregroundStyle(Theme.accent)
                Text(job.fileName)
                    .font(Theme.mono(13, .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            if job.isPDFSource {
                pdfControls
            } else if job.outputFormat.isTextLike {
                textControls
            } else {
                switch job.outputFormat.category {
                case .video:
                    videoControls
                case .audio:
                    audioControls
                default:
                    imageControls
                }
            }

            if let estimate = job.formattedEstimate {
                Divider()
                HStack {
                    Text("预计输出")
                    Spacer()
                    Text(estimate)
                        .foregroundStyle(Color.accentColor)
                        .font(.callout.monospacedDigit().weight(.semibold))
                }
                .font(.callout)
            }
        }
        .pickerStyle(.menu)
        .padding(18)
        #if os(macOS)
        .frame(width: 340)
        #else
        .frame(minWidth: 300)
        #endif
        .preferredColorScheme(.dark)
        .tint(Theme.accent)
    }

    // MARK: - Text documents & data

    @ViewBuilder
    private var textControls: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("文本与数据格式")
                .font(.callout.weight(.semibold))
            Text("Markdown、纯文本、HTML、Word、EPUB 之间互转无需任何参数；JSON、CSV、XML、plist 之间同理。全部在本机完成，文件不会离开这台设备。")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - PDF

    @ViewBuilder
    private var pdfControls: some View {
        LabeledContent("旋转页面") { rotationPicker }

        LabeledContent("页码范围") {
            TextField("all", text: $job.pageRange)
                .textFieldStyle(.roundedBorder)
                .font(.callout.monospacedDigit())
                .multilineTextAlignment(.trailing)
                .frame(width: 110)
        }

        LabeledContent("分辨率") {
            Picker("分辨率", selection: $job.pdfQuality) {
                ForEach(PDFQuality.allCases) { option in
                    Text(option.rawValue).tag(option)
                }
            }
            .labelsHidden()
        }

        Toggle("裁掉白边", isOn: $job.trimMargins)

        Text("写法如 1-3, 7（留空 = 全部）。旋转、裁剪与分辨率会同时作用于导出的图片和压缩后的 PDF。")
            .font(.caption)
            .foregroundStyle(.tertiary)

        Divider()

        qualitySlider
        if job.outputFormat == .png || job.outputFormat == .tiff {
            Text("PNG / TIFF 为无损格式，质量参数只作用于 JPEG 与压缩后的 PDF。")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: - Video

    @ViewBuilder
    private var videoControls: some View {
        LabeledContent("分辨率") {
            Picker("分辨率", selection: $job.videoResolution) {
                ForEach(VideoResolution.allCases) { option in
                    Text(option.rawValue).tag(option)
                }
            }
            .labelsHidden()
        }

        LabeledContent("编码") {
            Picker("编码", selection: $job.videoCodec) {
                ForEach(VideoCodec.allCases) { option in
                    Text(option.rawValue).tag(option)
                }
            }
            .labelsHidden()
        }

        Picker("体积控制", selection: sizingModeBinding) {
            ForEach(SizingMode.allCases) { mode in
                Text(mode.rawValue).tag(mode)
            }
        }
        .pickerStyle(.segmented)

        switch job.videoSizing {
        case .auto:
            Text("由编码器根据分辨率自动选择最佳码率。")
                .font(.caption)
                .foregroundStyle(.tertiary)
        case .bitrate:
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("视频码率")
                    Spacer()
                    Text(String(format: "%.1f Mbps", bitrateBinding.wrappedValue))
                        .foregroundStyle(.secondary)
                        .font(.callout.monospacedDigit())
                }
                Slider(value: bitrateBinding, in: 0.5...20, step: 0.5)
            }
        case .targetSize:
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("目标文件大小")
                    Spacer()
                    Text("\(Int(targetSizeBinding.wrappedValue)) MB")
                        .foregroundStyle(.secondary)
                        .font(.callout.monospacedDigit())
                }
                Slider(value: targetSizeBinding, in: 5...500, step: 5)
                Text("码率由目标体积反推 —— 目标过小会明显降低画质。")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }

        LabeledContent("音轨") {
            Picker("音轨", selection: $job.audioKbps) {
                ForEach(audioBitrateChoices, id: \.self) { kbps in
                    Text("\(kbps) kbps").tag(kbps)
                }
            }
            .labelsHidden()
        }

        Divider()
        trimControls
    }

    // MARK: - Audio

    @ViewBuilder
    private var audioControls: some View {
        if job.outputFormat == .m4a {
            LabeledContent("码率（AAC）") {
                Picker("码率（AAC）", selection: $job.audioKbps) {
                    ForEach(audioBitrateChoices, id: \.self) { kbps in
                        Text("\(kbps) kbps").tag(kbps)
                    }
                }
                .labelsHidden()
            }
        } else {
            Text("\(job.outputFormat.displayName) 是无压缩的 16-bit PCM，没有可调的质量参数。")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }

        Divider()

        LabeledContent("速度") {
            Picker("速度", selection: $job.audioSpeed) {
                ForEach(audioSpeedChoices, id: \.self) { speed in
                    Text(speed == 1.0 ? "原速" : String(format: "%g×", speed))
                        .tag(speed)
                }
            }
            .labelsHidden()
        }
        if job.audioSpeed != 1.0 {
            Text("变速不变调 —— 任何倍速下人声都保持自然。")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }

        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("音量")
                Spacer()
                Text(job.gainDB == 0 ? "0 dB" : String(format: "%+.0f dB", job.gainDB))
                    .foregroundStyle(.secondary)
                    .font(.callout.monospacedDigit())
            }
            Slider(value: $job.gainDB, in: -12...12, step: 1)
        }

        LabeledContent("淡入") {
            HStack(spacing: 8) {
                Text(String(format: "%.1f s", job.fadeInSeconds))
                    .foregroundStyle(.secondary)
                    .font(.callout.monospacedDigit())
                Stepper("淡入", value: $job.fadeInSeconds, in: 0...15, step: 0.5)
                    .labelsHidden()
            }
        }
        LabeledContent("淡出") {
            HStack(spacing: 8) {
                Text(String(format: "%.1f s", job.fadeOutSeconds))
                    .foregroundStyle(.secondary)
                    .font(.callout.monospacedDigit())
                Stepper("淡出", value: $job.fadeOutSeconds, in: 0...15, step: 0.5)
                    .labelsHidden()
            }
        }

        Divider()
        trimControls
    }

    // MARK: - Images / PDF output

    @ViewBuilder
    private var imageControls: some View {
        qualitySlider

        LabeledContent("旋转") { rotationPicker }

        LabeledContent("Resize") {
            Picker("Resize", selection: $job.imageResize) {
                ForEach(ImageResize.allCases) { option in
                    Text(option.rawValue).tag(option)
                }
            }
            .labelsHidden()
        }
    }

    // MARK: - Shared pieces

    private var qualitySlider: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("图片质量")
                Spacer()
                Text("\(Int(job.imageQuality * 100))%")
                    .foregroundStyle(.secondary)
                    .font(.callout.monospacedDigit())
            }
            Slider(value: $job.imageQuality, in: 0.3...1.0)
        }
    }

    private var rotationPicker: some View {
        Picker("旋转", selection: $job.rotation) {
            ForEach(RotationAngle.allCases) { angle in
                Text(angle.label).tag(angle)
            }
        }
        .labelsHidden()
    }

    @ViewBuilder
    private var trimControls: some View {
        LabeledContent("裁剪") {
            HStack(spacing: 6) {
                TextField("0:00", text: $job.trimStartText)
                TextField(endPlaceholder, text: $job.trimEndText)
            }
            .textFieldStyle(.roundedBorder)
            .font(.callout.monospacedDigit())
            .multilineTextAlignment(.trailing)
            .frame(width: 140)
        }
        Text("起止时间写 m:ss（例如 1:30）。留空表示不裁剪该端。")
            .font(.caption)
            .foregroundStyle(.tertiary)
    }

    private var endPlaceholder: String {
        job.durationSeconds.map(formatTimecode) ?? "结束"
    }

    // MARK: - Bindings

    private var sizingModeBinding: Binding<SizingMode> {
        Binding {
            switch job.videoSizing {
            case .auto:       return .auto
            case .bitrate:    return .bitrate
            case .targetSize: return .target
            }
        } set: { mode in
            switch mode {
            case .auto:    job.videoSizing = .auto
            case .bitrate: job.videoSizing = .bitrate(5)
            case .target:  job.videoSizing = .targetSize(defaultTargetMB)
            }
        }
    }

    private var defaultTargetMB: Double {
        // Start from roughly 60% of the source size, snapped to 5 MB steps.
        let mb = Double(job.fileSize) / 1_000_000 * 0.6
        return max(5, min(500, (mb / 5).rounded() * 5))
    }

    private var bitrateBinding: Binding<Double> {
        Binding {
            if case .bitrate(let mbps) = job.videoSizing { return mbps }
            return 5
        } set: { job.videoSizing = .bitrate($0) }
    }

    private var targetSizeBinding: Binding<Double> {
        Binding {
            if case .targetSize(let mb) = job.videoSizing { return mb }
            return defaultTargetMB
        } set: { job.videoSizing = .targetSize($0) }
    }
}
