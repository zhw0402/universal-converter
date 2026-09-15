//
//  DocumentPicker.swift
//  万能转换
//
//  SwiftUI's `.fileImporter` hands back a security-scoped URL that has to
//  be coordinated by hand — and when anything goes wrong it simply never
//  calls back, so the failure is invisible. Driving
//  `UIDocumentPickerViewController` directly fixes both problems: we get
//  a delegate we control, and `asCopy: true` makes the system copy the
//  file into our sandbox first, which also forces iCloud placeholders to
//  download before we ever try to read them.
//

import SwiftUI
import UniformTypeIdentifiers
import UIKit

enum DocumentPickerMode {
    case files
    case folder
}

struct DocumentPicker: UIViewControllerRepresentable {

    let mode: DocumentPickerMode
    let onPick: ([URL]) -> Void

    init(mode: DocumentPickerMode, onPick: @escaping ([URL]) -> Void) {
        self.mode = mode
        self.onPick = onPick
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onPick: onPick)
    }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let controller: UIDocumentPickerViewController
        switch mode {
        case .files:
            controller = UIDocumentPickerViewController(forOpeningContentTypes: ImportSupport.openableTypes,
                                                        asCopy: true)
            controller.allowsMultipleSelection = true
        case .folder:
            controller = UIDocumentPickerViewController(forOpeningContentTypes: [.folder],
                                                        asCopy: false)
            controller.allowsMultipleSelection = false
        }
        controller.delegate = context.coordinator
        controller.shouldShowFileExtensions = true
        return controller
    }

    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        private let onPick: ([URL]) -> Void

        init(onPick: @escaping ([URL]) -> Void) {
            self.onPick = onPick
        }

        func documentPicker(_ controller: UIDocumentPickerViewController,
                            didPickDocumentsAt urls: [URL]) {
            onPick(urls)
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            onPick([])
        }
    }
}
