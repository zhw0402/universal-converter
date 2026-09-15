//
//  ImageProcessor.swift
//  Verto
//
//  Still-image conversion and compression built on ImageIO — the same
//  engine Preview and Photos use. Handles EXIF orientation, animated
//  GIF passthrough, downscaling, and alpha flattening for JPEG/BMP.
//

import Foundation
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers

struct ImageProcessor {

    // MARK: - Image → Image

    static func convert(source: URL,
                        to format: OutputFormat,
                        settings: ConversionSettings,
                        outputDirectory: URL) throws -> [URL] {

        guard let destType = format.imageUTType else {
            throw ConversionError.unsupportedConversion
        }
        guard let imageSource = CGImageSourceCreateWithURL(source as CFURL, nil),
              CGImageSourceGetCount(imageSource) > 0 else {
            throw ConversionError.cannotOpenSource
        }

        let baseName = source.deletingPathExtension().lastPathComponent
        let destination = ConversionEngine.uniqueDestination(in: outputDirectory,
                                                             baseName: baseName,
                                                             fileExtension: format.fileExtension)
        let frameCount = CGImageSourceGetCount(imageSource)

        // Animated GIF → GIF: copy every frame with its timing intact.
        // (When a rotation is requested, each frame is decoded, rotated and
        // re-added with its own timing dictionary.)
        if format == .gif, frameCount > 1 {
            guard let dest = CGImageDestinationCreateWithURL(destination as CFURL,
                                                             UTType.gif.identifier as CFString,
                                                             frameCount, nil) else {
                throw ConversionError.encodingFailed("无法创建 GIF 输出")
            }
            if let containerProperties = CGImageSourceCopyProperties(imageSource, nil) {
                CGImageDestinationSetProperties(dest, containerProperties)
            }
            for index in 0..<frameCount {
                if settings.rotation != .none {
                    // Fail loudly rather than write a mixed-orientation GIF.
                    guard let frame = CGImageSourceCreateImageAtIndex(imageSource, index, nil) else {
                        throw ConversionError.encodingFailed("could not decode GIF frame \(index + 1)")
                    }
                    let rotated = RasterOps.rotate(frame, by: settings.rotation)
                    let frameProperties = CGImageSourceCopyPropertiesAtIndex(imageSource, index, nil)
                    CGImageDestinationAddImage(dest, rotated, frameProperties)
                } else {
                    CGImageDestinationAddImageFromSource(dest, imageSource, index, nil)
                }
            }
            guard CGImageDestinationFinalize(dest) else {
                throw ConversionError.encodingFailed("无法写入 GIF")
            }
            return [destination]
        }

        // Single frame: decode with orientation applied, optionally downscaled.
        var image = try decodedImage(from: imageSource, maxPixelSize: settings.maxPixelSize)

        // User rotation (on top of the already-applied EXIF orientation).
        if settings.rotation != .none {
            image = RasterOps.rotate(image, by: settings.rotation)
        }

        // JPEG and BMP have no alpha channel — flatten onto white instead of black.
        if (format == .jpeg || format == .bmp), hasAlpha(image) {
            image = flattenOntoWhite(image) ?? image
        }

        var options: [CFString: Any] = [:]
        if format == .jpeg || format == .heic {
            options[kCGImageDestinationLossyCompressionQuality] = settings.imageQuality
        }

        guard let dest = CGImageDestinationCreateWithURL(destination as CFURL,
                                                         destType.identifier as CFString,
                                                         1, nil) else {
            throw ConversionError.encodingFailed("无法创建输出文件")
        }
        CGImageDestinationAddImage(dest, image, options as CFDictionary)
        guard CGImageDestinationFinalize(dest) else {
            throw ConversionError.encodingFailed("could not write \(format.displayName)")
        }
        return [destination]
    }

    // MARK: - Image → PDF

    static func imageToPDF(source: URL,
                           settings: ConversionSettings,
                           outputDirectory: URL) throws -> [URL] {

        guard let imageSource = CGImageSourceCreateWithURL(source as CFURL, nil),
              CGImageSourceGetCount(imageSource) > 0 else {
            throw ConversionError.cannotOpenSource
        }
        var image = try decodedImage(from: imageSource, maxPixelSize: settings.maxPixelSize)
        if settings.rotation != .none {
            image = RasterOps.rotate(image, by: settings.rotation)
        }

        let baseName = source.deletingPathExtension().lastPathComponent
        let destination = ConversionEngine.uniqueDestination(in: outputDirectory,
                                                             baseName: baseName,
                                                             fileExtension: "pdf")

        var mediaBox = CGRect(x: 0, y: 0, width: CGFloat(image.width), height: CGFloat(image.height))
        guard let context = CGContext(destination as CFURL, mediaBox: &mediaBox, nil) else {
            throw ConversionError.encodingFailed("无法创建 PDF 上下文")
        }
        context.beginPDFPage(nil)
        context.draw(image, in: mediaBox)
        context.endPDFPage()
        context.closePDF()

        return [destination]
    }

    // MARK: - Helpers

    /// Full decode via the thumbnail API: applies EXIF rotation and caps size in one step.
    private static func decodedImage(from source: CGImageSource, maxPixelSize: CGFloat?) throws -> CGImage {
        var pixelCap = maxPixelSize
        if pixelCap == nil,
           let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {
            let w = (props[kCGImagePropertyPixelWidth] as? CGFloat) ?? 0
            let h = (props[kCGImagePropertyPixelHeight] as? CGFloat) ?? 0
            pixelCap = max(w, h)
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: pixelCap ?? 16_384
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw ConversionError.cannotOpenSource
        }
        return image
    }

    private static func hasAlpha(_ image: CGImage) -> Bool {
        switch image.alphaInfo {
        case .none, .noneSkipLast, .noneSkipFirst: return false
        default: return true
        }
    }

    private static func flattenOntoWhite(_ image: CGImage) -> CGImage? {
        guard let context = CGContext(data: nil,
                                      width: image.width,
                                      height: image.height,
                                      bitsPerComponent: 8,
                                      bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return nil
        }
        let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(rect)
        context.draw(image, in: rect)
        return context.makeImage()
    }
}
