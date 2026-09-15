//
//  PDFProcessor.swift
//  Verto
//
//  PDF → images and PDF compression using Core Graphics directly.
//  Compression re-renders each page and embeds it as JPEG (DCT), which
//  is what dedicated PDF shrinkers do under the hood.
//
//  1.1 adds real page tools: rotation, page-range selection ("1-3,7"),
//  and automatic white-margin trimming — applied uniformly to both the
//  PDF → images and the PDF → PDF paths.
//

import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

struct PDFProcessor {

    // MARK: - PDF → Images

    static func toImages(source: URL,
                         format: OutputFormat,
                         settings: ConversionSettings,
                         outputDirectory: URL,
                         progress: @escaping @Sendable (Double) -> Void) throws -> [URL] {

        guard let destType = format.imageUTType else {
            throw ConversionError.unsupportedConversion
        }
        guard let document = CGPDFDocument(source as CFURL), document.numberOfPages > 0 else {
            throw ConversionError.cannotOpenSource
        }

        let baseName = source.deletingPathExtension().lastPathComponent
        let pageNumbers = parsePageRange(settings.pageRange, pageCount: document.numberOfPages)
        var results: [URL] = []

        do {
            for (index, pageNumber) in pageNumbers.enumerated() {
                try Task.checkCancellation()
                guard let page = document.page(at: pageNumber),
                      let rendered = render(page: page, settings: settings) else { continue }

                let name = pageNumbers.count == 1 ? baseName : "\(baseName)-\(pageNumber)"
                let destination = ConversionEngine.uniqueDestination(in: outputDirectory,
                                                                     baseName: name,
                                                                     fileExtension: format.fileExtension)
                var options: [CFString: Any] = [:]
                if format == .jpeg {
                    options[kCGImageDestinationLossyCompressionQuality] = settings.imageQuality
                }
                guard let dest = CGImageDestinationCreateWithURL(destination as CFURL,
                                                                 destType.identifier as CFString,
                                                                 1, nil) else {
                    throw ConversionError.encodingFailed("无法创建输出文件")
                }
                CGImageDestinationAddImage(dest, rendered, options as CFDictionary)
                guard CGImageDestinationFinalize(dest) else {
                    throw ConversionError.encodingFailed("could not write page \(pageNumber)")
                }
                results.append(destination)
                progress(Double(index + 1) / Double(pageNumbers.count))
            }
        } catch {
            // Cancelled or failed mid-run: don't leave a half-exported batch behind.
            for url in results { try? FileManager.default.removeItem(at: url) }
            throw error
        }

        guard !results.isEmpty else { throw ConversionError.encodingFailed("没有渲染出任何页面") }
        return results
    }

    // MARK: - PDF → smaller PDF

    static func compress(source: URL,
                         settings: ConversionSettings,
                         outputDirectory: URL,
                         progress: @escaping @Sendable (Double) -> Void) throws -> [URL] {

        guard let document = CGPDFDocument(source as CFURL), document.numberOfPages > 0 else {
            throw ConversionError.cannotOpenSource
        }

        let pageNumbers = parsePageRange(settings.pageRange, pageCount: document.numberOfPages)
        let baseName = source.deletingPathExtension().lastPathComponent + " compressed"
        let destination = ConversionEngine.uniqueDestination(in: outputDirectory,
                                                             baseName: baseName,
                                                             fileExtension: "pdf")
        guard let context = CGContext(destination as CFURL, mediaBox: nil, nil) else {
            throw ConversionError.encodingFailed("无法创建 PDF 上下文")
        }

        var written = 0
        do {
            for (index, pageNumber) in pageNumbers.enumerated() {
                try Task.checkCancellation()
                guard let page = document.page(at: pageNumber),
                      let rendered = render(page: page, settings: settings) else { continue }

                // Encode the rendered page as JPEG…
                let jpegData = NSMutableData()
                guard let jpegDest = CGImageDestinationCreateWithData(jpegData,
                                                                      UTType.jpeg.identifier as CFString,
                                                                      1, nil) else { continue }
                let quality = [kCGImageDestinationLossyCompressionQuality: settings.imageQuality]
                CGImageDestinationAddImage(jpegDest, rendered, quality as CFDictionary)
                guard CGImageDestinationFinalize(jpegDest) else { continue }

                // …and rebuild a CGImage from that JPEG stream so the PDF context
                // embeds the compressed DCT data instead of a lossless bitmap.
                guard let provider = CGDataProvider(data: jpegData),
                      let jpegImage = CGImage(jpegDataProviderSource: provider,
                                              decode: nil,
                                              shouldInterpolate: true,
                                              intent: .defaultIntent) else { continue }

                // Page size in points follows the rendered bitmap, so rotation and
                // margin-trim carry through to the output page geometry.
                let scale = settings.pdfDPI / 72.0
                var pageBox = CGRect(x: 0, y: 0,
                                     width: CGFloat(rendered.width) / scale,
                                     height: CGFloat(rendered.height) / scale)

                let boxData = withUnsafeBytes(of: &pageBox) { Data($0) }
                let pageInfo = [kCGPDFContextMediaBox as String: boxData] as CFDictionary

                context.beginPDFPage(pageInfo)
                context.draw(jpegImage, in: pageBox)
                context.endPDFPage()
                written += 1
                progress(Double(index + 1) / Double(pageNumbers.count))
            }
        } catch {
            // Cancelled or failed mid-run: close the context and remove the
            // half-written PDF instead of leaving a corrupt file behind.
            context.closePDF()
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
        context.closePDF()

        guard written > 0 else {
            try? FileManager.default.removeItem(at: destination)
            throw ConversionError.encodingFailed("没有渲染出任何页面")
        }
        return [destination]
    }

    // MARK: - Rendering

    /// Rasterise one PDF page at the requested DPI (white background,
    /// embedded page rotation handled), then apply the user's edits:
    /// white-margin trim first, extra rotation second.
    private static func render(page: CGPDFPage, settings: ConversionSettings) -> CGImage? {
        guard var image = render(page: page, dpi: settings.pdfDPI) else { return nil }
        if settings.trimMargins {
            image = RasterOps.trimWhiteMargins(image)
        }
        if settings.rotation != .none {
            image = RasterOps.rotate(image, by: settings.rotation)
        }
        return image
    }

    private static func render(page: CGPDFPage, dpi: CGFloat) -> CGImage? {
        let box = page.getBoxRect(.cropBox)
        let scale = dpi / 72.0
        let rotated = abs(page.rotationAngle % 180) == 90

        let width  = max(1, Int(((rotated ? box.height : box.width) * scale).rounded()))
        let height = max(1, Int(((rotated ? box.width : box.height) * scale).rounded()))

        guard let context = CGContext(data: nil,
                                      width: width,
                                      height: height,
                                      bitsPerComponent: 8,
                                      bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return nil
        }
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .high

        let transform = page.getDrawingTransform(.cropBox,
                                                 rect: CGRect(x: 0, y: 0, width: width, height: height),
                                                 rotate: 0,
                                                 preserveAspectRatio: true)
        context.concatenate(transform)
        context.drawPDFPage(page)
        return context.makeImage()
    }
}
