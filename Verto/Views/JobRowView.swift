//
//  JobRowView.swift
//  Verto
//
//  One file in the queue: thumbnail, name, target format picker,
//  per-file tuning, estimated output size, live ASCII progress, and
//  result actions (reveal in Finder on macOS, share sheet on iOS).
//

import SwiftUI
#if os(macOS)
import AppKit
#endif

struct JobRowView: View {
    @ObservedObject var job: ConversionJob
    @EnvironmentObject private var app: AppState
    @State private var isTunePresented = false
    @State private var hovering = false
    @State private var completedGlow = false

    var body: some View {
        HStack(spacing: 12) {
            thumbnailView

            VStack(alignment: .leading, spacing: 3) {
                Text(job.fileName)
                    .font(Theme.mono(13, .medium))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 6) {
                    Text("\(job.sourceURL.pathExtension.uppercased()) · \(job.formattedSize)")
                    if let estimate = job.formattedEstimate {
                        Text("→ \(estimate)")
                            .foregroundStyle(Theme.accent.opacity(0.9))
                    }
                }
                .font(Theme.mono(11))
                .foregroundStyle(Theme.textDim)

                // Active edits at a glance: ↻90° · p.1-5 · ✂0:10–1:30 · 1.5×
                if !job.editBadges.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(job.editBadges, id: \.self) { badge in
                            Text(badge)
                                .font(Theme.mono(9.5))
                                .foregroundStyle(Theme.accent.opacity(0.9))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1.5)
                                .background(
                                    RoundedRectangle(cornerRadius: 4)
                                        .fill(Theme.accent.opacity(0.08))
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 4)
                                                .strokeBorder(Theme.accent.opacity(0.22))
                                        )
                                )
                        }
                    }
                    .padding(.top, 1)
                }
            }

            Spacer(minLength: 12)

            statusView
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .terminalCard(hovering: hovering)
        .shadow(color: Theme.accent.opacity(completedGlow ? 0.28 : 0),
                radius: 9, y: 0)
        .onHover { over in
            withAnimation(.easeOut(duration: 0.13)) { hovering = over }
        }
        .onChange(of: job.status) { _, newStatus in
            if case .completed = newStatus {
                withAnimation(.easeIn(duration: 0.15)) { completedGlow = true }
                Task {
                    try? await Task.sleep(nanoseconds: 900_000_000)
                    withAnimation(.easeOut(duration: 0.8)) { completedGlow = false }
                }
            }
        }
    }

    // MARK: - Pieces

    private var thumbnailView: some View {
        Group {
            if let thumbnail = job.thumbnail {
                #if os(macOS)
                Image(nsImage: thumbnail)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                #else
                Image(uiImage: thumbnail)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                #endif
            } else {
                Image(systemName: placeholderIcon)
                    .font(.title3)
                    .foregroundStyle(Theme.textDim)
            }
        }
        .frame(width: 42, height: 42)
        .background(Color.black.opacity(0.35))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.white.opacity(0.08))
        )
    }

    @ViewBuilder
    private var statusView: some View {
        switch job.status {
        case .waiting:
            Picker("输出格式", selection: $job.outputFormat) {
                ForEach(job.availableFormats) { format in
                    Text(label(for: format)).tag(format)
                }
            }
            .labelsHidden()
            .fixedSize()
            .disabled(app.isConverting)   // batch snapshots settings at start

            Button {
                isTunePresented.toggle()
            } label: {
                Image(systemName: "dial.high")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(Theme.textDim)
            .help("此文件的质量与体积")
            .disabled(app.isConverting)
            .popover(isPresented: $isTunePresented, arrowEdge: .bottom) {
                JobOptionsView(job: job)
            }

            removeButton

        case .converting(let fraction):
            AsciiProgressBar(fraction: fraction)
            Text("\(Int(fraction * 100))%")
                .font(Theme.mono(11))
                .contentTransition(.numericText())
                .animation(.default, value: Int(fraction * 100))
                .foregroundStyle(Theme.textDim)
                .frame(width: 34, alignment: .trailing)

        case .completed(let outputs):
            Text("✓ \(resultText(for: outputs))")
                .font(Theme.mono(12, .medium))
                .foregroundStyle(Theme.accent)
            #if os(macOS)
            Button {
                NSWorkspace.shared.activateFileViewerSelecting(outputs)
            } label: {
                Image(systemName: "magnifyingglass")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(Theme.textDim)
            .help("在「文件」中显示")
            #else
            ShareLink(items: outputs) {
                Image(systemName: "square.and.arrow.up")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(Theme.textDim)
            #endif

        case .failed(let message):
            Text("✗ 失败")
                .font(Theme.mono(12, .medium))
                .foregroundStyle(Theme.danger)
                .help(message)

            removeButton
        }
    }

    private var removeButton: some View {
        Button {
            app.remove(job)
        } label: {
            Image(systemName: "xmark")
                .font(.caption.weight(.bold))
                .foregroundStyle(Theme.textDim)
        }
        .buttonStyle(.borderless)
        .help("从列表中移除")
        .disabled(app.isConverting)
    }

    private func label(for format: OutputFormat) -> String {
        format.isSameFormat(as: job.sourceType)
            ? "\(format.displayName) — compress"
            : format.displayName
    }

    private func resultText(for outputs: [URL]) -> String {
        if outputs.count > 1 { return "\(outputs.count) files" }
        if let first = outputs.first,
           let size = try? first.resourceValues(forKeys: [.fileSizeKey]).fileSize {
            return ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
        }
        return job.summary
    }

    private var placeholderIcon: String {
        switch OutputFormat.compatibleFormats(for: job.sourceType).first?.category {
        case .video:    return "film"
        case .audio:    return "waveform"
        case .document: return "doc.richtext"
        default:        return "photo"
        }
    }
}
