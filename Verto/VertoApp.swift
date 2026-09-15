//
//  VertoApp.swift
//  Verto
//
//  Convert & compress anything. Natively. macOS · iOS · iPadOS.
//

import SwiftUI

@main
struct VertoApp: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
        }
        #if os(macOS)
        .defaultSize(width: 840, height: 580)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("打开文件…") {
                    appState.requestAddFiles()
                }
                .keyboardShortcut("o", modifiers: .command)

                Button("Choose Output Folder…") {
                    appState.requestOutputFolder()
                }
                .keyboardShortcut("o", modifiers: [.command, .shift])

                Divider()

                Button("全部转换") {
                    appState.convertAll()
                }
                .keyboardShortcut(.return, modifiers: .command)
            }
        }
        #endif
    }
}
