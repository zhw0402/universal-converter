//
//  TerminalBackdrop.swift
//  Verto
//
//  The signature 1.1 background: a faint, endless stream of conversion
//  logs scrolling behind the interface — like glancing at the machine
//  room through smoked glass. Pure decoration: it never steals a tap
//  and it goes still when Reduce Motion is on.
//

import SwiftUI

struct TerminalBackdrop: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let lineHeight: CGFloat = 21
    private static let scrollDuration: Double = 52   // one full loop, seconds

    var body: some View {
        ZStack {
            LinearGradient(colors: [Theme.bgTop, Theme.bgBottom],
                           startPoint: .top, endPoint: .bottom)

            GeometryReader { geo in
                let stackHeight = CGFloat(Self.lines.count) * Self.lineHeight
                // Enough repeats to cover any window height while one copy scrolls out.
                let copies = max(2, Int(ceil(geo.size.height / stackHeight)) + 1)

                // Clock-driven at a capped 20 fps: survives backgrounding,
                // pauses under Reduce Motion, and never pins ProMotion at 120 Hz.
                TimelineView(.animation(minimumInterval: 1.0 / 20,
                                        paused: reduceMotion)) { timeline in
                    let t = timeline.date.timeIntervalSinceReferenceDate
                        .truncatingRemainder(dividingBy: Self.scrollDuration)
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(0..<(Self.lines.count * copies), id: \.self) { index in
                            let line = Self.lines[index % Self.lines.count]
                            Text(line.text)
                                .font(.system(size: 11.5, design: .monospaced))
                                .foregroundStyle(line.accent ? Theme.accent : .white)
                                .opacity(line.accent ? 0.30 : 0.17)
                                .lineLimit(1)
                                .fixedSize()
                                .frame(height: Self.lineHeight, alignment: .leading)
                        }
                    }
                    .padding(.leading, 22)
                    .offset(y: -CGFloat(t / Self.scrollDuration) * stackHeight)
                }
            }
            .opacity(0.35)
            .clipped()

            // Readability veil: darker at the top and bottom edges.
            LinearGradient(stops: [
                .init(color: Theme.bgTop.opacity(0.55), location: 0),
                .init(color: .clear, location: 0.28),
                .init(color: .clear, location: 0.66),
                .init(color: Theme.bgBottom.opacity(0.65), location: 1),
            ], startPoint: .top, endPoint: .bottom)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    // MARK: - The log itself
    //
    // Handwritten and deterministic — believable output from a day of
    // ordinary conversions, not random noise.

    private static let lines: [(text: String, accent: Bool)] = [
        ("$ verto --batch ~/Inbox --out ~/Converted", true),
        ("[23:39:02] 扫描       IMG_0421.heic              3.1 MB", false),
        ("[23:39:02] 转换       IMG_0421.heic → jpeg        q=0.85", false),
        ("[23:39:03] 完成       IMG_0421.jpg               612 KB   −80%", true),
        ("[23:39:03] 扫描       IMG_0422.heic              2.8 MB", false),
        ("[23:39:04] 完成       IMG_0422.jpg               548 KB   −80%", true),
        ("[23:39:05] 转换       主图.png → heic             无损", false),
        ("[23:39:05] 完成       主图.heic                  212 KB   −64%", true),
        ("[23:39:07] 扫描       网课-14.mov                412 MB", false),
        ("[23:39:07] 转码       网课-14.mov → mp4           hevc · 1080p", false),
        ("[23:39:08] ....       ██████░░░░░░  48%          剩余 0:22", false),
        ("[23:39:31] 完成       网课-14.mp4                96.4 MB  −77%", true),
        ("$ verto convert thesis-draft.pdf --pages jpeg --dpi 150", true),
        ("[23:40:10] 渲染       第 1/24 页 → jpeg           150 dpi", false),
        ("[23:40:12] 渲染       第 24/24 页 → jpeg          150 dpi", false),
        ("[23:40:12] 完成       24 个文件                  18.2 MB", true),
        ("[23:40:40] 扫描       录音-032.m4a               14.1 MB", false),
        ("[23:40:41] 转换       录音-032.m4a → wav         44.1 kHz · 16-bit", false),
        ("[23:40:44] 完成       录音-032.wav               82.9 MB  pcm", true),
        ("[23:41:02] 转换       截图-3.png → jpeg           q=0.85 · 展平", false),
        ("[23:41:02] 完成       截图-3.jpg                 148 KB   −71%", true),
        ("[23:41:15] 转码       宣传片.mov → mp4            目标 25 MB", false),
        ("[23:41:16] ....       ██████████░░  83%          码率 4.6 Mbps", false),
        ("[23:41:29] 完成      宣传片.mp4                  24.8 MB  命中目标", true),
        ("[23:41:30] 队列       空闲 — 无待处理任务", false),
        ("$ █", true),
    ]
}

#Preview {
    TerminalBackdrop()
        .frame(width: 800, height: 560)
}
