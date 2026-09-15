//
//  OptionsView.swift
//  Verto
//
//  Global defaults applied to newly added files. Every file can then be
//  tuned individually with the dial button on its row.
//

import SwiftUI

struct OptionsView: View {
    @EnvironmentObject private var app: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 7) {
                Text("$")
                    .font(Theme.mono(13, .semibold))
                    .foregroundStyle(Theme.accent)
                Text("default options")
                    .font(Theme.mono(13, .semibold))
                    .foregroundStyle(Theme.textPrimary)
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("图片质量")
                    Spacer()
                    Text("\(Int(app.imageQuality * 100))%")
                        .foregroundStyle(.secondary)
                        .font(.callout.monospacedDigit())
                }
                Slider(value: $app.imageQuality, in: 0.3...1.0)
                Text("影响 JPEG / HEIC 输出，以及 PDF 压缩。")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            Divider()

            labeledPicker("调整尺寸", selection: $app.imageResize, ImageResize.allCases)
            labeledPicker("视频分辨率", selection: $app.videoResolution, VideoResolution.allCases)
            labeledPicker("视频编码", selection: $app.videoCodec, VideoCodec.allCases)

            LabeledContent("音频码率") {
                Picker("音频码率", selection: $app.audioKbps) {
                    ForEach(audioBitrateChoices, id: \.self) { kbps in
                        Text("\(kbps) kbps").tag(kbps)
                    }
                }
                .labelsHidden()
            }

            labeledPicker("PDF 分辨率", selection: $app.pdfQuality, PDFQuality.allCases)

            Divider()

            Label("点每一行的调节按钮，可为单个文件设置码率或精确体积。",
                  systemImage: "dial.high")
                .font(.caption)
                .foregroundStyle(.secondary)
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

    /// Menu picker with a label that stays visible on iOS too.
    private func labeledPicker<T: CaseIterable & Identifiable & Hashable>(
        _ title: String, selection: Binding<T>, _ options: [T]
    ) -> some View where T: RawRepresentable, T.RawValue == String {
        LabeledContent(title) {
            Picker(title, selection: selection) {
                ForEach(options) { option in
                    Text(option.rawValue).tag(option)
                }
            }
            .labelsHidden()
        }
    }
}

#Preview {
    OptionsView()
        .environmentObject(AppState())
}
