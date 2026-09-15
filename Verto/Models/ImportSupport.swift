//
//  ImportSupport.swift
//  万能转换
//
//  The set of types the file picker offers.
//
//  Using `.item` on its own — the abstract root of the type hierarchy —
//  is what the previous build passed, and on some iOS versions the picker
//  will happily let you select a file and then never hand it back. Every
//  type we can actually handle is therefore listed explicitly, with
//  `.data` as the catch-all so nothing is hidden from the user.
//

import Foundation
import UniformTypeIdentifiers

enum ImportSupport {

    static let openableTypes: [UTType] = {
        var types: [UTType] = [
            // Images
            .image, .jpeg, .png, .heic, .tiff, .bmp, .gif, .webP, .ico, .rawImage,
            // Video
            .movie, .video, .mpeg4Movie, .quickTimeMovie,
            // Audio
            .audio, .mp3, .mpeg4Audio, .wav, .aiff,
            // Documents & structured data
            .pdf, .plainText, .utf8PlainText, .html, .rtf,
            .json, .xml, .commaSeparatedText, .propertyList
        ]

        // Types with no static constant on UTType.
        for identifier in ["org.openxmlformats.wordprocessingml.document",
                           "org.idpf.epub-container",
                           "net.daringfireball.markdown"] {
            if let type = UTType(identifier) {
                types.append(type)
            }
        }

        // Catch-all so a file we don't know about is still selectable —
        // `addFiles` reports it instead of dropping it silently.
        types.append(.data)

        return types
    }()
}
