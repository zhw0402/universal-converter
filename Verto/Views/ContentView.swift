//
//  ContentView.swift
//  Verto
//
//  Window, toolbar, drag & drop, pickers — wrapped in the 1.1 terminal
//  dark theme with the animated log backdrop.
//

import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject private var app: AppState
    @State private var isDropTargeted = false
    @State private var isOptionsPresented = false

    var body: some View {
        #if os(macOS)
        core
        #else
        NavigationStack { core }
        #endif
    }

    private var core: some View {
        Group {
            if app.jobs.isEmpty {
                DropZoneView()
            } else {
                queueView
            }
        }
        #if os(macOS)
        .frame(minWidth: 700, minHeight: 460)
        #endif
        .background { TerminalBackdrop() }
        .preferredColorScheme(.dark)
        .tint(Theme.accent)
        .navigationTitle("万能转换")
        .toolbar { toolbarContent }
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            handleDrop(providers)
        }
        .overlay {
            DropTargetOverlay(active: isDropTargeted)
        }
        .sheet(isPresented: $app.isPickerPresented) {
            DocumentPicker(mode: app.pickerRequest == .outputFolder ? .folder : .files) { urls in
                app.isPickerPresented = false
                guard !urls.isEmpty else { return }
                switch app.pickerRequest {
                case .files:
                    app.addFiles(urls)
                case .outputFolder:
                    if let url = urls.first {
                        app.setOutputDirectory(url)
                    }
                }
            }
            .ignoresSafeArea()
        }
        .alert("有文件没能导入", isPresented: importNoticeBinding) {
            Button("知道了", role: .cancel) {}
        } message: {
            Text(app.importNotice ?? "")
        }
        .onOpenURL { url in
            // "用万能转换打开" / 分享到本 App
            guard url.isFileURL else { return }
            app.addFiles([url])
        }
    }

    /// Lets the alert dismiss itself by clearing the notice.
    private var importNoticeBinding: Binding<Bool> {
        Binding(get: { app.importNotice != nil },
                set: { if !$0 { app.importNotice = nil } })
    }

    // MARK: - Queue

    private var queueView: some View {
        VStack(spacing: 0) {
            statusLine

            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(app.jobs) { job in
                        JobRowView(job: job)
                            .transition(.asymmetric(
                                insertion: .move(edge: .top).combined(with: .opacity),
                                removal: .opacity))
                    }
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 14)
                .animation(.spring(duration: 0.35), value: app.jobs.map(\.id))
            }

            bottomBar
        }
    }

    /// The little `$ verto …` prompt above the queue.
    private var statusLine: some View {
        HStack(spacing: 8) {
            Text("$")
                .font(Theme.mono(12, .semibold))
                .foregroundStyle(Theme.accent)
            Text(statusText)
                .font(Theme.mono(12))
                .foregroundStyle(Theme.textDim)
                .contentTransition(.numericText())
                .animation(.default, value: statusText)
            BlinkingCursor()
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 10)
    }

    private var statusText: String {
        if app.isConverting {
            let active = app.jobs.filter {
                if case .converting = $0.status { return true }
                return false
            }.count
            return "正在转换 \(active) / \(app.jobs.count) 个文件"
        }
        if app.finishedCount == app.jobs.count {
            return "已完成 · 共 \(app.jobs.count) 个文件"
        }
        return "已排队 \(app.jobs.count) 个文件"
    }

    private var bottomBar: some View {
        HStack(spacing: 12) {
            Button {
                app.requestOutputFolder()
            } label: {
                Label(app.outputDirectory?.lastPathComponent ?? "选择输出文件夹…",
                      systemImage: "folder")
                    .lineLimit(1)
            }
            .buttonStyle(TerminalGhostButtonStyle())
            .help("转换后的文件保存在此文件夹")

            Spacer()

            if app.isConverting {
                BrailleSpinner()
                Text("转换中…")
                    .font(Theme.mono(12))
                    .foregroundStyle(Theme.textDim)
                Button("取消") {
                    app.cancelConversion()
                }
                .buttonStyle(TerminalGhostButtonStyle(tint: Theme.danger))
            } else {
                if app.finishedCount > 0 {
                    Text("已完成 \(app.finishedCount) / \(app.jobs.count)")
                        .font(Theme.mono(12))
                        .foregroundStyle(Theme.textDim)
                        .contentTransition(.numericText())
                }
                Button {
                    app.convertAll()
                } label: {
                    Label("开始转换", systemImage: "arrow.triangle.2.circlepath")
                        .frame(minWidth: 92)
                }
                .buttonStyle(TerminalPrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)
                .disabled(!app.canConvert)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(
            Theme.panel.opacity(0.88)
                .overlay(alignment: .top) {
                    Theme.hairline.frame(height: 1)
                }
                .ignoresSafeArea(edges: .bottom)
        )
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                app.requestAddFiles()
            } label: {
                Label("添加文件", systemImage: "plus")
            }
            .help("添加文件")

            Button {
                isOptionsPresented.toggle()
            } label: {
                Label("选项", systemImage: "slider.horizontal.3")
            }
            .help("默认质量与压缩参数")
            .popover(isPresented: $isOptionsPresented, arrowEdge: .bottom) {
                OptionsView()
            }

            Button {
                app.clearAll()
            } label: {
                Label("清空", systemImage: "trash")
            }
            .help("移除列表中的全部文件")
            .disabled(app.jobs.isEmpty || app.isConverting)
        }
    }

    // MARK: - Drop handling

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        var handled = false
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            handled = true
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                let url: URL?
                if let data = item as? Data {
                    url = URL(dataRepresentation: data, relativeTo: nil)
                } else if let itemURL = item as? URL {
                    url = itemURL
                } else {
                    url = nil
                }
                if let url {
                    Task { @MainActor in
                        app.addFiles([url])
                    }
                }
            }
        }
        return handled
    }
}

// MARK: - Drop target overlay

/// Marching-ants border plus a small "松开即可添加" chip while a drag
/// hovers over the window.
private struct DropTargetOverlay: View {
    var active: Bool

    var body: some View {
        ZStack {
            if active {
                TimelineView(.animation) { timeline in
                    let phase = timeline.date.timeIntervalSinceReferenceDate * 26
                    RoundedRectangle(cornerRadius: 16)
                        .strokeBorder(Theme.accent,
                                      style: StrokeStyle(lineWidth: 2,
                                                         dash: [10, 6],
                                                         dashPhase: -phase.truncatingRemainder(dividingBy: 16)))
                        .background(
                            Theme.accent.opacity(0.05),
                            in: RoundedRectangle(cornerRadius: 16)
                        )
                }
                .padding(10)

                Text("▼ 松开以添加文件")
                    .font(Theme.mono(13, .semibold))
                    .foregroundStyle(Theme.accent)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(
                        Capsule()
                            .fill(Theme.bgBottom.opacity(0.92))
                            .overlay(Capsule().strokeBorder(Theme.accent.opacity(0.5)))
                    )
                    .transition(.scale(scale: 0.9).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.14), value: active)
        .allowsHitTesting(false)
    }
}

#Preview {
    ContentView()
        .environmentObject(AppState())
}
