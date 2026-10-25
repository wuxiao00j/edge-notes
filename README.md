# 贴边便签 · EdgeNotes

macOS 原生贴边便签：停靠在屏幕右缘，悬停呼出；侧栏与桌面贴纸统一外观。SwiftUI + AppKit。

A native macOS edge sticky-notes app. Docks to the right screen edge, peeks on hover. Built with SwiftUI + AppKit.

**要求 / Requirements:** macOS 14+ · Apple Silicon & Intel (universal)

## 功能 Highlights

- 贴边侧栏 / 桌面贴纸，经典六色
- Markdown WYSIWYG：粗体、列表、可勾选待办、拖放图片、可点击链接（默认浏览器，单击只开一次）
- 提醒、快捷键、速藏、备份 / 导出、回收站、历史版本

## 下载 Download

见 [Releases](https://github.com/wuxiao00j/edge-notes/releases) 中的 `EdgeNotes-macOS.zip`。解压后将 `EdgeNotes.app` 拖到「应用程序」。

> 当前为 ad-hoc 签名。首次打开若被拦截：右键 → 打开，或在「系统设置 → 隐私与安全性」中允许。

## 从源码构建 Build

```bash
brew install xcodegen   # 若尚未安装
cd edge-notes
xcodegen generate
xcodebuild -scheme EdgeNotes -configuration Release -derivedDataPath build build
open build/Build/Products/Release/EdgeNotes.app
```

Debug：

```bash
xcodebuild -scheme EdgeNotes -configuration Debug -derivedDataPath build build
open build/Build/Products/Debug/EdgeNotes.app
```

## 快捷键 Shortcuts（设置里可改）

| 功能 | 默认 |
|------|------|
| 显示/隐藏侧栏 | ⌥⌘N |
| 极速新建 | ⌥⌘T |
| 选区优先，否则剪贴板 → 新便签 | ⌥⇧⌘V |

**选区贴入**需要「系统设置 → 隐私与安全性 → 辅助功能」允许本 App；未授权时回退到剪贴板。

## 数据 Data

`~/Library/Application Support/EdgeNotes/`  
附件：`…/Attachments/`  
无 iCloud / 无云同步。

## 许可 License

MIT — 见 [LICENSE](./LICENSE)。
