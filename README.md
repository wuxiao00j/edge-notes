# 贴边便签 · EdgeNotes

macOS 原生「挂绳」便签：菜单栏下方一根晾衣绳，鼠标停一下就放下来，便签、图片、链接、文件和剪贴板历史都夹在上面。SwiftUI + AppKit。

A native macOS "clothesline" for notes: a rope under the menu bar drops down when you hover, holding notes, images, links, files and your clipboard history. Built with SwiftUI + AppKit. English and Simplified Chinese UI.

**要求 / Requirements:** macOS 14+ · Apple Silicon & Intel (universal)

## 功能 Highlights

- **挂绳**：鼠标移到菜单栏正下方停一下就放下并置顶，离开自动收起，空白处点击穿透；可钉住不收起；多显示器跟随鼠标；卡片小 / 中 / 大三档
- **什么都能挂**：图片、文字、网页链接（自动取标题和网站图标）、本地文件（只记位置不复制，文件移动后自动找回）
- **单击**：图片看大图，文字进入编辑，链接打开网页，文件直接打开；**点夹子取下**；左右拖动换位置，往下拖出来可放进其它 App 的输入框
- **剪贴板历史**：复制过的文字、图片、文件收进绳上的一张大卡片，点一下再次复制；密码管理器等隐私内容不记录
- 卡片多了自动缩小、再叠放，悬停的那张提到最前；可设置挂满 N 天自动取下
- **全部便签**窗口：搜索（支持拼音、首字母，命中高亮）、Markdown 编辑、标签、提醒、锁定（Touch ID）、历史版本、归档、回收站、导出 / 备份
- 提醒走系统通知，App 退出也会响；快捷指令 / Siri 动作；Sparkle 自动更新

## 下载 Download

见 [Releases](https://github.com/wuxiao00j/edge-notes/releases) 中的 `EdgeNotes-macOS.zip`。解压后将 `EdgeNotes.app` 拖到「应用程序」。之后的新版本会在 App 内提示更新。

> 目前仍是 ad-hoc 签名（苹果公证准备中）。首次打开若被拦截：右键 → 打开，或在「系统设置 → 隐私与安全性」中允许。

## 快捷键 Shortcuts（设置里可改）

| 功能 | 默认 |
|------|------|
| 显示 / 隐藏全部便签 | ⌥⌘N |
| 新建挂绳便签 | ⌥⌘T |
| 剪贴板 → 挂绳 | ⌥⇧⌘H |

## 从源码构建 Build

```bash
brew install xcodegen   # 若尚未安装
cd edge-notes
xcodegen generate
xcodebuild -scheme EdgeNotes -configuration Release -derivedDataPath build build
open build/Build/Products/Release/EdgeNotes.app
```

单元测试（使用临时目录，不碰真实数据）：

```bash
xcodebuild test -scheme EdgeNotes -derivedDataPath build
```

## 发布 Release（维护者）

一次性准备：

1. 在 Xcode → Settings → Accounts → Manage Certificates 里创建 **Developer ID Application** 证书
2. 保存公证凭据（会提示输入 App 专用密码）：`xcrun notarytool store-credentials edgenotes --apple-id <邮箱> --team-id <TEAMID>`
3. Sparkle 更新签名私钥已在登录钥匙串（`generate_keys` 生成），换电脑前用 `generate_keys -x 文件` 导出备份

之后每次发布，在 `main` 上：

```bash
TEAM_ID=<TEAMID> scripts/release.sh 0.6.0 6
```

脚本会：跑测试 → Developer ID 签名 + Hardened Runtime → 公证并装订 → Sparkle 签名 → 更新 `appcast.xml` → 打标签并发布 GitHub Release。

## 数据 Data

`~/Library/Application Support/EdgeNotes/`  
附件：`…/Attachments/`（无引用的附件会自动清理）  
剪贴板历史：`…/clipboard.json`、`…/ClipboardHistory/`（最近 40 条）  
每日备份：`…/Backups/`（保留 7 天）；回收站 30 天后自动清空  
无 iCloud / 无云同步。

## 许可 License

MIT — 见 [LICENSE](./LICENSE)。
