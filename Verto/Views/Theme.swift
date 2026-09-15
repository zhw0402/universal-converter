//
//  Theme.swift
//  Verto
//
//  The 1.1 design language: a quiet, terminal-inspired dark theme.
//  One palette, one monospaced type ramp, the pixel-face mark, and the
//  two button styles used everywhere.
//

import SwiftUI

// MARK: - Palette & type

enum Theme {
    // Backgrounds
    static let bgTop     = Color(red: 0.075, green: 0.090, blue: 0.110)
    static let bgBottom  = Color(red: 0.039, green: 0.047, blue: 0.059)
    static let panel     = Color(red: 0.086, green: 0.102, blue: 0.122)
    static let panelHover = Color(red: 0.106, green: 0.125, blue: 0.149)

    // Strokes
    static let hairline  = Color.white.opacity(0.07)

    // Content
    static let textPrimary = Color(red: 0.941, green: 0.949, blue: 0.929)
    static let textDim     = Color(red: 0.560, green: 0.600, blue: 0.620)
    static let accent      = Color(red: 0.302, green: 0.871, blue: 0.561)   // phosphor green
    static let amber       = Color(red: 0.910, green: 0.706, blue: 0.290)
    static let danger      = Color(red: 0.878, green: 0.420, blue: 0.380)

    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}

// MARK: - Pixel face mark

/// The app mark: the same 16×16 pixel-grid face as the icon, drawn live.
/// It idly blinks, and its little green cursor pulses like a real prompt.
struct PixelFaceView: View {
    var faceColor: Color = Theme.textPrimary
    var cursorColor: Color = Theme.accent
    var animated: Bool = true

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var eyesClosed = false
    @State private var cursorOn = true

    // (x, y, w, h) in grid units — mirrors scripts/make_icon.py
    private static let eyes: [(Double, Double, Double, Double)] = [
        (4, 3, 1, 2), (11, 3, 1, 2),
    ]
    private static let eyesBlink: [(Double, Double, Double, Double)] = [
        (4, 4, 1, 1), (11, 4, 1, 1),
    ]
    private static let rest: [(Double, Double, Double, Double)] = [
        (7, 8, 1.6, 1),               // nose foot
        (8, 3, 1, 6),                 // nose column
        (5, 10, 1, 1), (10, 10, 1, 1),
        (6, 11, 4, 1),                // smile
    ]
    private static let cursor: (Double, Double, Double, Double) = (10, 13, 2, 1)

    var body: some View {
        Canvas { context, size in
            let cell = size.width / 16
            func fill(_ r: (Double, Double, Double, Double), _ color: Color) {
                let rect = CGRect(x: r.0 * cell, y: r.1 * cell,
                                  width: r.2 * cell, height: r.3 * cell)
                context.fill(Path(roundedRect: rect, cornerRadius: cell * 0.1),
                             with: .color(color))
            }
            for r in (eyesClosed ? Self.eyesBlink : Self.eyes) { fill(r, faceColor) }
            for r in Self.rest { fill(r, faceColor) }
            fill(Self.cursor, cursorColor.opacity(cursorOn ? 1 : 0.25))
        }
        .aspectRatio(1, contentMode: .fit)
        .task {
            guard animated, !reduceMotion else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 3_800_000_000)
                eyesClosed = true
                try? await Task.sleep(nanoseconds: 130_000_000)
                eyesClosed = false
            }
        }
        .task {
            guard animated, !reduceMotion else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 560_000_000)
                cursorOn.toggle()
            }
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Small terminal widgets

/// The classic blinking block cursor.
struct BlinkingCursor: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if reduceMotion {
            block.opacity(0.85)
        } else {
            TimelineView(.periodic(from: .now, by: 0.55)) { timeline in
                let on = Int(timeline.date.timeIntervalSinceReferenceDate / 0.55) % 2 == 0
                block.opacity(on ? 0.85 : 0.15)
            }
        }
    }

    private var block: some View {
        Text("▉")
            .font(Theme.mono(11))
            .foregroundStyle(Theme.accent)
    }
}

/// A braille spinner, the way real CLIs do it.
struct BrailleSpinner: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let frames = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.08, paused: reduceMotion)) { timeline in
            let index = Int(timeline.date.timeIntervalSinceReferenceDate / 0.08)
                % Self.frames.count
            Text(Self.frames[index])
                .font(Theme.mono(13, .semibold))
                .foregroundStyle(Theme.accent)
        }
        .accessibilityLabel("Converting")
    }
}

/// `██████░░░░░░`-style progress, monospaced so it never jitters.
struct AsciiProgressBar: View {
    var fraction: Double
    var cells: Int = 12

    var body: some View {
        let filled = min(cells, max(0, Int(fraction * Double(cells))))
        return (
            Text(String(repeating: "█", count: filled))
                .foregroundStyle(Theme.accent)
            + Text(String(repeating: "░", count: cells - filled))
                .foregroundStyle(Color.white.opacity(0.16))
        )
        .font(Theme.mono(12))
        .accessibilityLabel("Progress \(Int(fraction * 100)) percent")
    }
}

// MARK: - Button styles

/// Filled accent button — the one primary action on screen.
struct TerminalPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.mono(13, .semibold))
            .foregroundStyle(Theme.bgBottom)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Theme.accent)
                    .opacity(isEnabled ? (configuration.isPressed ? 0.75 : 1) : 0.3)
            )
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// Quiet bordered button for secondary actions.
struct TerminalGhostButtonStyle: ButtonStyle {
    var tint: Color = Theme.textDim

    func makeBody(configuration: Configuration) -> some View {
        GhostLabel(configuration: configuration, tint: tint)
    }

    /// Inner view so hover state has a stable view identity.
    private struct GhostLabel: View {
        let configuration: Configuration
        let tint: Color

        @Environment(\.isEnabled) private var isEnabled
        @State private var hovering = false

        var body: some View {
            configuration.label
                .font(Theme.mono(12))
                .foregroundStyle(hovering ? Theme.textPrimary : tint)
                .padding(.horizontal, 11)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 7)
                        .fill(Color.white.opacity(hovering ? 0.07 : 0.03))
                        .overlay(
                            RoundedRectangle(cornerRadius: 7)
                                .strokeBorder(Color.white.opacity(hovering ? 0.18 : 0.10))
                        )
                )
                .opacity(isEnabled ? 1 : 0.35)
                .scaleEffect(configuration.isPressed ? 0.97 : 1)
                .onHover { hovering = $0 }
                .animation(.easeOut(duration: 0.12), value: hovering)
                .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
        }
    }
}

// MARK: - Card container

struct TerminalCard: ViewModifier {
    var hovering = false

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(hovering ? Theme.panelHover : Theme.panel)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(hovering ? Theme.accent.opacity(0.28) : Theme.hairline)
                    )
            )
    }
}

extension View {
    func terminalCard(hovering: Bool = false) -> some View {
        modifier(TerminalCard(hovering: hovering))
    }
}
