//
//  AppState.swift
//  Verto
//
//  The single source of truth: the queue, global defaults, the output
//  folder (security-scoped bookmark on macOS, Documents on iOS), and
//  the batch runner with bounded concurrency.
//

import SwiftUI
import AVFoundation
import QuickLookThumbnailing
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#endif

@MainActor
final class AppState: ObservableObject {

    // MARK: - Queue

    @Published var jobs: [ConversionJob] = []
    @Published var isConverting = false

    // File picker (used on iOS; macOS uses NSOpenPanel directly).
    // ONE importer with two modes: attaching multiple .fileImporter
    // modifiers to the same view conflicts in SwiftUI and the picker
    // silently fails to present on iOS.
    enum PickerRequest {
        case files, outputFolder
    }
    @Published var isPickerPresented = false
    /// Non-nil when a batch of files was rejected — shown as an alert.
    @Published var importNotice: String?
    var pickerRequest: PickerRequest = .files

    // MARK: - Output folder

    @Published private(set) var outputDirectory: URL?
    private static let bookmarkKey = "app.verto.outputFolderBookmark"

    // MARK: - Global defaults (persisted; each new file starts from these)

    @Published var imageQuality: Double {
        didSet { UserDefaults.standard.set(imageQuality, forKey: "app.verto.imageQuality") }
    }
    @Published var imageResize: ImageResize {
        didSet { UserDefaults.standard.set(imageResize.rawValue, forKey: "app.verto.imageResize") }
    }
    @Published var videoResolution: VideoResolution {
        didSet { UserDefaults.standard.set(videoResolution.rawValue, forKey: "app.verto.videoResolution") }
    }
    @Published var videoCodec: VideoCodec {
        didSet { UserDefaults.standard.set(videoCodec.rawValue, forKey: "app.verto.videoCodec") }
    }
    @Published var audioKbps: Int {
        didSet { UserDefaults.standard.set(audioKbps, forKey: "app.verto.audioKbps") }
    }
    @Published var pdfQuality: PDFQuality {
        didSet { UserDefaults.standard.set(pdfQuality.rawValue, forKey: "app.verto.pdfQuality") }
    }

    private var conversionTask: Task<Void, Never>?

    init() {
        let defaults = UserDefaults.standard
        imageQuality    = defaults.object(forKey: "app.verto.imageQuality") as? Double ?? 0.85
        imageResize     = ImageResize(rawValue: defaults.string(forKey: "app.verto.imageResize") ?? "") ?? .original
        videoResolution = VideoResolution(rawValue: defaults.string(forKey: "app.verto.videoResolution") ?? "") ?? .original
        videoCodec      = VideoCodec(rawValue: defaults.string(forKey: "app.verto.videoCodec") ?? "") ?? .h264
        audioKbps       = defaults.object(forKey: "app.verto.audioKbps") as? Int ?? 128
        pdfQuality      = PDFQuality(rawValue: defaults.string(forKey: "app.verto.pdfQuality") ?? "") ?? .dpi150
        restoreOutputDirectory()
        #if os(iOS)
        if outputDirectory == nil {
            // Sensible default on iPhone/iPad: the app's Documents folder,
            // visible in the Files app under "On My iPhone → Verto".
            outputDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        }
        #endif
    }

    private var jobDefaults: JobDefaults {
        JobDefaults(imageQuality: imageQuality,
                    imageResize: imageResize,
                    videoResolution: videoResolution,
                    videoCodec: videoCodec,
                    audioKbps: audioKbps,
                    pdfQuality: pdfQuality)
    }

    // MARK: - Adding files

    func addFiles(_ urls: [URL]) {
        let existing = Set(jobs.map { $0.sourceURL.path })
        var rejected: [String] = []

        for url in urls where !existing.contains(url.path) {
            let accessing = url.startAccessingSecurityScopedResource()
            let job = ConversionJob(url: url, defaults: jobDefaults)
            if accessing { url.stopAccessingSecurityScopedResource() }

            guard let job else {
                // Silence here used to look like "nothing happened at all",
                // so report what iOS told us the file actually is.
                let values = try? url.resourceValues(forKeys: [.contentTypeKey])
                let identifier = values?.contentType?.identifier ?? "未知类型"
                rejected.append("· \(url.lastPathComponent)  [\(identifier)]")
                continue
            }

            jobs.append(job)
            loadMetadata(for: job)
        }

        if !rejected.isEmpty {
            importNotice = "以下文件暂时无法转换：\n"
                + rejected.joined(separator: "\n")
                + "\n\n把这段内容发给我，我就能把对应格式补上。"
        }
    }

    func requestAddFiles() {
        #if os(macOS)
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.message = "选择要转换的文件"
        panel.prompt = "Add"
        if panel.runModal() == .OK {
            addFiles(panel.urls)
        }
        #else
        pickerRequest = .files
        isPickerPresented = true
        #endif
    }

    /// Thumbnail + duration (for the size estimate), off the main thread.
    private func loadMetadata(for job: ConversionJob) {
        Task {
            let accessing = job.sourceURL.startAccessingSecurityScopedResource()
            defer { if accessing { job.sourceURL.stopAccessingSecurityScopedResource() } }

            let request = QLThumbnailGenerator.Request(fileAt: job.sourceURL,
                                                       size: CGSize(width: 56, height: 56),
                                                       scale: 2,
                                                       representationTypes: .thumbnail)
            if let representation = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) {
                #if os(macOS)
                job.thumbnail = representation.nsImage
                #else
                job.thumbnail = representation.uiImage
                #endif
            }

            if job.sourceType.conforms(to: .audiovisualContent) {
                let asset = AVURLAsset(url: job.sourceURL)
                if let duration = try? await asset.load(.duration).seconds, duration.isFinite {
                    job.durationSeconds = duration
                }
            }
        }
    }

    // MARK: - Output folder

    func requestOutputFolder() {
        #if os(macOS)
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "转换后的文件将保存在此文件夹"
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url {
            setOutputDirectory(url)
        }
        #else
        pickerRequest = .outputFolder
        isPickerPresented = true
        #endif
    }

    func setOutputDirectory(_ url: URL) {
        outputDirectory?.stopAccessingSecurityScopedResource()
        _ = url.startAccessingSecurityScopedResource()
        outputDirectory = url
        #if os(macOS)
        let options: URL.BookmarkCreationOptions = .withSecurityScope
        #else
        let options: URL.BookmarkCreationOptions = []
        #endif
        if let bookmark = try? url.bookmarkData(options: options,
                                                includingResourceValuesForKeys: nil,
                                                relativeTo: nil) {
            UserDefaults.standard.set(bookmark, forKey: Self.bookmarkKey)
        }
    }

    private func restoreOutputDirectory() {
        guard let data = UserDefaults.standard.data(forKey: Self.bookmarkKey) else { return }
        var isStale = false
        #if os(macOS)
        let options: URL.BookmarkResolutionOptions = .withSecurityScope
        #else
        let options: URL.BookmarkResolutionOptions = []
        #endif
        guard let url = try? URL(resolvingBookmarkData: data,
                                 options: options,
                                 relativeTo: nil,
                                 bookmarkDataIsStale: &isStale) else { return }
        _ = url.startAccessingSecurityScopedResource()
        outputDirectory = url
    }

    // MARK: - Conversion

    var canConvert: Bool {
        !isConverting && jobs.contains { $0.status == .waiting }
    }

    private func settings(for job: ConversionJob) -> ConversionSettings {
        ConversionSettings(imageQuality: job.imageQuality,
                           maxPixelSize: job.imageResize.maxPixelSize,
                           pdfDPI: job.pdfQuality.dpi,
                           videoCodec: job.videoCodec,
                           videoResolution: job.videoResolution,
                           videoSizing: job.videoSizing,
                           audioKbps: job.audioKbps,
                           rotation: job.rotation,
                           pageRange: job.pageRange,
                           trimMargins: job.trimMargins,
                           audioSpeed: job.audioSpeed,
                           gainDB: job.gainDB,
                           fadeInSeconds: job.fadeInSeconds,
                           fadeOutSeconds: job.fadeOutSeconds,
                           trimStart: job.trimStartSeconds,
                           trimEnd: job.trimEndSeconds)
    }

    func convertAll() {
        guard canConvert else { return }
        if outputDirectory == nil {
            requestOutputFolder()
            guard outputDirectory != nil else { return }
        }
        guard let outputDir = outputDirectory else { return }

        // Snapshot everything on the main actor before going wide.
        let workItems: [(ConversionJob, OutputFormat, ConversionSettings)] =
            jobs.filter { $0.status == .waiting }
                .map { ($0, $0.outputFormat, settings(for: $0)) }
        guard !workItems.isEmpty else { return }

        isConverting = true
        conversionTask = Task {
            await withTaskGroup(of: Void.self) { group in
                let maxConcurrent = 2
                var nextIndex = 0

                func enqueue(into group: inout TaskGroup<Void>) {
                    guard nextIndex < workItems.count, !Task.isCancelled else { return }
                    let (job, format, settings) = workItems[nextIndex]
                    nextIndex += 1
                    group.addTask {
                        await Self.process(job: job, format: format,
                                           settings: settings, outputDirectory: outputDir)
                    }
                }

                for _ in 0..<min(maxConcurrent, workItems.count) { enqueue(into: &group) }
                for await _ in group { enqueue(into: &group) }
            }
            isConverting = false
        }
    }

    func cancelConversion() {
        conversionTask?.cancel()
    }

    nonisolated private static func process(job: ConversionJob,
                                            format: OutputFormat,
                                            settings: ConversionSettings,
                                            outputDirectory: URL) async {
        if Task.isCancelled { return }
        await MainActor.run { job.status = .converting(0) }

        let accessing = job.sourceURL.startAccessingSecurityScopedResource()
        defer {
            if accessing { job.sourceURL.stopAccessingSecurityScopedResource() }
        }

        do {
            let outputs = try await ConversionEngine.convert(
                source: job.sourceURL,
                sourceType: job.sourceType,
                to: format,
                settings: settings,
                outputDirectory: outputDirectory,
                progress: { fraction in
                    Task { @MainActor in
                        if case .converting = job.status {
                            job.status = .converting(min(max(fraction, 0), 1))
                        }
                    }
                })
            await MainActor.run { job.status = .completed(outputs) }
        } catch is CancellationError {
            await MainActor.run { job.status = .waiting }
        } catch {
            await MainActor.run { job.status = .failed(error.localizedDescription) }
        }
    }

    // MARK: - Queue management

    func remove(_ job: ConversionJob) {
        guard !isConverting else { return }
        jobs.removeAll { $0.id == job.id }
    }

    func clearAll() {
        guard !isConverting else { return }
        jobs.removeAll()
    }

    var finishedCount: Int {
        jobs.filter { $0.status.isFinished }.count
    }
}
