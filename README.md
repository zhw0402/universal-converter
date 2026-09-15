# 万能转换 (Universal Converter)

一个跑在 iPhone / iPad 上的**本地格式转换器**。图片、视频、音频、PDF、Word、EPUB、Markdown、JSON、CSV……装进同一个 App，
全部转换在设备上完成，不上传、不注册、没有文件大小限制。

> 本项目基于开源项目 **Verto**（MIT © 2026 Alessandro Gaudio）扩展而来：保留了它的图像 / 音视频 / PDF 引擎，
> 新增了完整中文界面、Word / EPUB / Markdown / HTML 互转、以及 JSON / CSV / XML / plist 互转。
> 原始 MIT 许可证见 `LICENSE`。

---

## 支持的转换

| 类别 | 输入 | 可输出 |
|---|---|---|
| 🖼 图片 | JPEG, PNG, HEIC, TIFF, BMP, GIF, WebP | JPEG, PNG, HEIC, TIFF, BMP, GIF, PDF |
| 📄 PDF | PDF | JPEG, PNG, TIFF（逐页），压缩后的 PDF |
| 🎬 视频 | MP4, MOV, M4V | MP4, MOV, M4V（H.264 / HEVC），并可从视频中提取音频 |
| 🎵 音频 | MP3, M4A, WAV, AIFF, CAF | M4A (AAC, 64–320 kbps), WAV, AIFF, CAF |
| 📝 文档 | DOCX, MD, TXT, HTML, RTF, EPUB | MD, TXT, HTML, DOCX, EPUB |
| 🔢 数据 | JSON, CSV, XML, plist | JSON, CSV, XML, plist |

附加能力：

- **压缩**：图片质量滑块、PDF 的 DPI、视频分辨率 / 码率 / 目标体积（可指定「压到 25 MB」）
- **编辑**：图片与 PDF 旋转、PDF 页码区间（`1-3, 7`）、PDF 自动裁白边、音视频起止裁剪、音频 0.5×–2× 变速（不变调）、音量增减、淡入淡出
- **Docx / EPUB 读写**：内置零依赖 ZIP 实现，直接解包 OOXML 与 EPUB，不需要任何第三方库
- **批量队列**：多选文件、逐个设置、实时进度与体积估算

---

## 构建（无需 Mac）

项目自带 GitHub Actions 工作流，用云端 macOS 编译出 **未签名 IPA**。

1. 把整个目录推到一个 GitHub 仓库（公开仓库的 macOS runner 免费）：

   ```bash
   cd universal-converter
   git init && git add -A
   git commit -m "万能转换 iOS 版"
   git branch -M main
   git remote add origin https://github.com/<你的用户名>/<仓库名>.git
   git push -u origin main
   ```

2. 打开仓库的 **Actions** 标签页，选择 **Build unsigned IPA**，点 **Run workflow**。
   （提交到 main 分支也会自动触发。）

3. 约 5–10 分钟后，在 Actions 运行页面的 **Artifacts** 里下载
   `UniversalConverter-unsigned-ipa`；同时在仓库 **Releases** 里也能拿到同一个 IPA。

工作流做的事：`xcodebuild -target Verto -sdk iphoneos -arch arm64` → 打包成 `Payload/*.app` → `zip` 成 IPA，
全程关闭代码签名（`CODE_SIGNING_ALLOWED=NO`）。

---

## 安装（必须重新签名）

未签名的 IPA **不能**直接拖进「文件」App 安装 —— iOS 只接受有有效签名的 App。请用以下任一方式：

| 方式 | 说明 |
|---|---|
| **Sideloadly** | Windows / macOS 都能用，接上数据线，填自己的 Apple ID 即可，免费证书 7 天有效 |
| **AltStore / SideStore** | 手机端自签，需要电脑端配合安装一次 AltServer |
| **爱思助手** | 国内常见，导入 IPA 后一键「签名安装」 |
| **有付费开发者账号** | 证书有效期 1 年，无需每 7 天重签 |

> 提示：免费 Apple ID 签名的 App 每 7 天需要重签一次，且同一时间最多 3 个。

---

## 目录结构

```
universal-converter/
├── Verto.xcodeproj/            # Xcode 工程（使用 Xcode 16 同步文件夹，新增文件会被自动纳入编译）
├── Verto/
│   ├── VertoApp.swift          # 入口
│   ├── AppState.swift          # 队列、设置、输出目录
│   ├── Models/
│   │   ├── OutputFormat.swift  # 所有可输出的格式 + 兼容性判定
│   │   ├── ConversionJob.swift # 单个任务（含体积估算）
│   │   └── ConversionSettings.swift
│   ├── Engine/
│   │   ├── ImageProcessor.swift      # 图片转换 / 转 PDF
│   │   ├── PDFProcessor.swift        # PDF 转图片 / 压缩
│   │   ├── AVProcessor.swift         # 音视频转码
│   │   ├── VideoTranscoder.swift     # AVAssetReader/Writer 管线
│   │   ├── AudioEffects.swift        # 变速、增益、淡入淡出
│   │   ├── ZipKit.swift              # ★ 新增：零依赖 ZIP 读写（raw DEFLATE + CRC32）
│   │   ├── Markup.swift              # ★ 新增：HTML ⇄ Markdown ⇄ 纯文本
│   │   ├── DocumentProcessor.swift   # ★ 新增：DOCX / EPUB / RTF / MD / HTML / TXT 读取
│   │   ├── DocumentWriter.swift      # ★ 新增：DOCX / EPUB / HTML 写出
│   │   └── DataProcessor.swift       # ★ 新增：JSON ⇄ CSV ⇄ XML ⇄ plist
│   └── Views/                  # SwiftUI 界面（已中文化）
├── .github/workflows/build-ipa.yml
└── tools/                      # 开发期辅助脚本（不参与 App 编译）
    ├── swiftcheck.py           # 括号 / 字符串字面量平衡检查
    ├── localize.py             # 英→中文案替换（可审计、可复现）
    ├── symbolcheck.py          # 跨文件符号一致性检查
    └── make_icon.py            # 生成 1024×1024 应用图标
```

---

## 自己改代码

- **加一种输出格式**：在 `Models/OutputFormat.swift` 里加 `case`，然后补齐 `displayName` / `category` /
  （文本类还需要 `isTextLike`）；再在 `Engine/ConversionEngine.swift` 里加一条路由。
  该文件里的 `switch` 都是穷尽式的，编译器会直接告诉你哪里漏了。
- **改界面文案**：直接用 Xcode 打开 `Verto.xcodeproj` 搜索中文即可；也可以在 `tools/localize.py`
  里改映射表后重跑，保持可追溯。
- **改包名 / 显示名**：`tools/rename_project.py` 里的映射表，或直接在 Xcode 的 Signing & Capabilities 里改。

## 已知边界

- iOS 无法调用 LibreOffice / FFmpeg，所以 **Office 家族只支持 Word (.docx) 的读取**，不支持 `.doc / .xls / .ppt`；
  音频也不能编码成 MP3（系统只提供 AAC 编码器），`.ogg` 同样不支持。
- 图片输出不含 WebP 编码（系统只提供 WebP 解码）。
- DOCX 里的图片、脚注、批注会被丢弃，只保留正文文字、标题层级、粗斜体和表格。
- EPUB 会把整本书合并成一份 Markdown；反过来 Markdown 转 EPUB 时按一级标题分章。

## 许可

本项目遵循 **MIT License**（见 `LICENSE`，原始版权归 Alessandro Gaudio）。
在此基础上新增的中文界面与文档 / 数据转换模块同样以 MIT 发布。
