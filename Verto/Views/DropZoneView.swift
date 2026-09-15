//
//  DropZoneView.swift
//  Verto
//
//  The empty state: the pixel-face mark, one clear instruction, and the
//  full format list — all in the terminal voice of the 1.1 redesign.
//

import SwiftUI

struct DropZoneView: View {
    @EnvironmentObject private var app: AppState

    private static let imageFormats = ["JPEG", "PNG", "HEIC", "TIFF", "BMP", "GIF", "WEBP", "PDF"]
    private static let avFormats = ["MP4", "MOV", "M4V", "MP3", "M4A", "WAV", "AIFF", "CAF"]

    var body: some View {
        VStack(spacing: 0) {
            PixelFaceView()
                .frame(width: 120, height: 120)
                .padding(.bottom, 22)

            Text("把文件拖到这里转换")
                .font(Theme.mono(23, .semibold))
                .foregroundStyle(Theme.textPrimary)

            Text(subtitle)
                .font(Theme.mono(12.5))
                .foregroundStyle(Theme.textDim)
                .padding(.top, 7)

            HStack(spacing: 9) {
                Text("$")
                    .font(Theme.mono(14, .semibold))
                    .foregroundStyle(Theme.accent)
                #if os(macOS)
                Text("拖到窗口任意位置，或")
                    .font(Theme.mono(12.5))
                    .foregroundStyle(Theme.textDim)
                #endif
                Button("浏览文件…") {
                    app.requestAddFiles()
                }
                .buttonStyle(TerminalGhostButtonStyle(tint: Theme.accent))
                BlinkingCursor()
            }
            .padding(.top, 24)

            // Two tidy rows where they fit, four narrower ones where they don't.
            ViewThatFits(in: .horizontal) {
                VStack(spacing: 7) {
                    formatRow(Self.imageFormats)
                    formatRow(Self.avFormats)
                }
                VStack(spacing: 7) {
                    formatRow(Array(Self.imageFormats.prefix(4)))
                    formatRow(Array(Self.imageFormats.suffix(4)))
                    formatRow(Array(Self.avFormats.prefix(4)))
                    formatRow(Array(Self.avFormats.suffix(4)))
                }
            }
            .padding(.top, 34)
        }
        .padding(edgePadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 22)
                .strokeBorder(Color.white.opacity(0.09),
                              style: StrokeStyle(lineWidth: 1.5, dash: [6, 8]))
        )
        .padding(outerPadding)
        .multilineTextAlignment(.center)
    }

    private var edgePadding: CGFloat {
        #if os(macOS)
        46
        #else
        22
        #endif
    }

    private var outerPadding: CGFloat {
        #if os(macOS)
        30
        #else
        14
        #endif
    }

    private var subtitle: String {
        #if os(macOS)
        "图片 · 视频 · 音频 · PDF · 文档 · 数据 — 全部在本机完成"
        #else
        "图片 · 视频 · 音频 · PDF · 文档 · 数据 — 全部在本机完成"
        #endif
    }

    private func formatRow(_ formats: [String]) -> some View {
        HStack(spacing: 6) {
            ForEach(formats, id: \.self) { name in
                Text(name)
                    .font(Theme.mono(10.5))
                    .foregroundStyle(Theme.textDim)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3.5)
                    .background(
                        RoundedRectangle(cornerRadius: 5)
                            .fill(Color.white.opacity(0.035))
                            .overlay(
                                RoundedRectangle(cornerRadius: 5)
                                    .strokeBorder(Color.white.opacity(0.08))
                            )
                    )
            }
        }
    }
}

#Preview {
    DropZoneView()
        .environmentObject(AppState())
        .background(TerminalBackdrop())
        .frame(width: 780, height: 560)
}
