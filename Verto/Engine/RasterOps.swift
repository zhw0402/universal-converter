//
//  RasterOps.swift
//  Verto
//
//  Small shared bitmap operations used by both the image and the PDF
//  pipelines: lossless-quality rotation and white-margin auto-trim.
//

import Foundation
import CoreGraphics

enum RasterOps {

    /// Rotate clockwise by the requested angle. `.none` returns the input.
    static func rotate(_ image: CGImage, by angle: RotationAngle) -> CGImage {
        guard angle != .none else { return image }

        let width = image.width
        let height = image.height
        let swaps = angle == .r90 || angle == .r270
        let newWidth = swaps ? height : width
        let newHeight = swaps ? width : height

        guard let context = CGContext(data: nil,
                                      width: newWidth,
                                      height: newHeight,
                                      bitsPerComponent: 8,
                                      bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return image
        }
        context.interpolationQuality = .high
        context.translateBy(x: CGFloat(newWidth) / 2, y: CGFloat(newHeight) / 2)
        // Negative angle = clockwise in Core Graphics' coordinate system.
        context.rotate(by: -CGFloat(angle.rawValue) * .pi / 180)
        context.draw(image, in: CGRect(x: -CGFloat(width) / 2,
                                       y: -CGFloat(height) / 2,
                                       width: CGFloat(width),
                                       height: CGFloat(height)))
        return context.makeImage() ?? image
    }

    /// Crop away near-white margins (used for scanned/exported PDF pages).
    /// Returns the input untouched when the page is blank or already tight.
    static func trimWhiteMargins(_ image: CGImage) -> CGImage {
        let width = image.width
        let height = image.height
        guard width > 8, height > 8 else { return image }

        // Draw into a known RGBA8 layout so the scan below is format-safe.
        guard let context = CGContext(data: nil,
                                      width: width,
                                      height: height,
                                      bitsPerComponent: 8,
                                      bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return image
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let data = context.data else { return image }

        let bytesPerRow = context.bytesPerRow
        let pixels = data.assumingMemoryBound(to: UInt8.self)
        let threshold: UInt8 = 242

        func rowHasContent(_ y: Int) -> Bool {
            let row = pixels + y * bytesPerRow
            for x in 0..<width {
                let p = row + x * 4
                if p[0] < threshold || p[1] < threshold || p[2] < threshold { return true }
            }
            return false
        }
        func columnHasContent(_ x: Int, from top: Int, to bottom: Int) -> Bool {
            for y in top...bottom {
                let p = pixels + y * bytesPerRow + x * 4
                if p[0] < threshold || p[1] < threshold || p[2] < threshold { return true }
            }
            return false
        }

        var top = 0
        while top < height, !rowHasContent(top) { top += 1 }
        guard top < height else { return image }   // blank page

        var bottom = height - 1
        while bottom > top, !rowHasContent(bottom) { bottom -= 1 }

        var left = 0
        while left < width, !columnHasContent(left, from: top, to: bottom) { left += 1 }
        var right = width - 1
        while right > left, !columnHasContent(right, from: top, to: bottom) { right -= 1 }

        // Breathing room so text doesn't kiss the edge.
        let pad = max(4, min(width, height) / 100)
        left = max(0, left - pad)
        right = min(width - 1, right + pad)
        top = max(0, top - pad)
        bottom = min(height - 1, bottom + pad)

        let cropWidth = right - left + 1
        let cropHeight = bottom - top + 1
        guard cropWidth > 0, cropHeight > 0,
              cropWidth < width || cropHeight < height else { return image }

        let crop = CGRect(x: left, y: top, width: cropWidth, height: cropHeight)
        return context.makeImage()?.cropping(to: crop) ?? image
    }
}
