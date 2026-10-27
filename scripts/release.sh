#!/bin/bash
# 发布新版本：Developer ID 签名 → 苹果公证 → 装订 → Sparkle 签名 → 更新 appcast.xml → GitHub Release
#
# 用法：scripts/release.sh <版本号> <构建号>      例：scripts/release.sh 0.6.0 6
#
# 一次性准备（见 README「发布」）：
#   1. 钥匙串里有「Developer ID Application」证书
#   2. 已保存公证凭据：xcrun notarytool store-credentials edgenotes --apple-id <邮箱> --team-id <TEAMID>
#   3. Sparkle 私钥在登录钥匙串里（generate_keys 生成过）
#   4. 环境变量 TEAM_ID=<你的 10 位 Team ID>
set -euo pipefail

VERSION="${1:?用法: scripts/release.sh <版本号> <构建号>}"
BUILD="${2:?用法: scripts/release.sh <版本号> <构建号>}"
TEAM_ID="${TEAM_ID:?请先 export TEAM_ID=<你的 Team ID>}"
NOTARY_PROFILE="${NOTARY_PROFILE:-edgenotes}"
# iCloud 同步需要的 Developer ID 描述文件（没有就照常发布，只是这个版本不能开 iCloud 同步）
PROFILE="${PROFILE:-signing/EdgeNotes_DeveloperID.provisionprofile}"
REPO="wuxiao00j/edge-notes"

cd "$(dirname "$0")/.."
ROOT="$PWD"
OUT="$ROOT/build/release"
APP="$OUT/Build/Products/Release/EdgeNotes.app"
ZIP="$ROOT/build/EdgeNotes-macOS.zip"
SPARKLE_BIN="$ROOT/build/SourcePackages/artifacts/sparkle/Sparkle/bin"

[ -z "$(git status --porcelain --untracked-files=no)" ] || { echo "工作区有未提交的改动，先提交再发布"; exit 1; }
# App 从 main 分支读取 appcast.xml：必须从 origin/main 的最新提交发布（分支名不限，可在 worktree 里跑）
git fetch -q origin
[ "$(git rev-parse HEAD)" = "$(git rev-parse origin/main)" ] || { echo "请先切到 origin/main 的最新提交再发布"; exit 1; }

echo "==> 版本号 $VERSION ($BUILD)"
sed -i '' -E "s/MARKETING_VERSION: \"[^\"]+\"/MARKETING_VERSION: \"$VERSION\"/; s/CURRENT_PROJECT_VERSION: \"[^\"]+\"/CURRENT_PROJECT_VERSION: \"$BUILD\"/" project.yml
xcodegen generate >/dev/null

echo "==> 运行单元测试"
xcodebuild test -scheme EdgeNotes -derivedDataPath build -quiet

echo "==> 构建（Developer ID + Hardened Runtime）"
rm -rf "$OUT"
EXTRA=()
if [ -f "$PROFILE" ]; then
  # 装进 Xcode 的描述文件目录，按 UUID 引用，并带上 iCloud 授权
  UUID_=$(security cms -D -i "$PROFILE" | plutil -extract UUID raw -)
  mkdir -p "$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"
  cp "$PROFILE" "$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles/$UUID_.provisionprofile"
  EXTRA=(CODE_SIGN_ENTITLEMENTS=EdgeNotes/EdgeNotes.entitlements PROVISIONING_PROFILE_SPECIFIER="$UUID_")
  echo "    带 iCloud 授权（描述文件 $UUID_）"
else
  echo "    没找到 $PROFILE：这个版本不带 iCloud 同步"
fi
xcodebuild -scheme EdgeNotes -configuration Release -derivedDataPath "$OUT" \
  -clonedSourcePackagesDirPath build/SourcePackages \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="Developer ID Application" DEVELOPMENT_TEAM="$TEAM_ID" \
  ENABLE_HARDENED_RUNTIME=YES OTHER_CODE_SIGN_FLAGS="--timestamp" "${EXTRA[@]}" -quiet build
# Sparkle 里的辅助程序也要用 Developer ID + Hardened Runtime 重签，否则公证不过（Sparkle 官方文档的做法）
ID="Developer ID Application"
FW="$APP/Contents/Frameworks/Sparkle.framework"
codesign -f -s "$ID" -o runtime --timestamp "$FW/Versions/B/XPCServices/Installer.xpc"
codesign -f -s "$ID" -o runtime --timestamp --preserve-metadata=entitlements "$FW/Versions/B/XPCServices/Downloader.xpc"
codesign -f -s "$ID" -o runtime --timestamp "$FW/Versions/B/Autoupdate"
codesign -f -s "$ID" -o runtime --timestamp "$FW/Versions/B/Updater.app"
codesign -f -s "$ID" -o runtime --timestamp "$FW"
codesign -f -s "$ID" -o runtime --timestamp --preserve-metadata=entitlements "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"

echo "==> 公证（几分钟）"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$APP"
spctl --assess --type execute --verbose "$APP"
# 装订后重新打包，用户离线也能通过 Gatekeeper
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

echo "==> Sparkle 签名并更新 appcast.xml"
SIG_ATTRS="$("$SPARKLE_BIN/sign_update" "$ZIP")"   # sparkle:edSignature="…" length="…"
URL="https://github.com/$REPO/releases/download/v$VERSION/EdgeNotes-macOS.zip"
python3 - "$VERSION" "$BUILD" "$URL" "$SIG_ATTRS" <<'PY'
import sys, email.utils
version, build, url, sig = sys.argv[1:5]
item = f"""    <item>
      <title>{version}</title>
      <pubDate>{email.utils.formatdate(localtime=True)}</pubDate>
      <sparkle:version>{build}</sparkle:version>
      <sparkle:shortVersionString>{version}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
      <link>https://github.com/wuxiao00j/edge-notes/releases/tag/v{version}</link>
      <enclosure url="{url}" {sig} type="application/octet-stream"/>
    </item>
"""
p = "appcast.xml"
s = open(p).read()
s = s.replace("  </channel>", item + "  </channel>", 1) if "<item>" not in s else s.replace("    <item>", item + "    <item>", 1)
open(p, "w").write(s)
PY

echo "==> 提交版本号与 appcast，打标签，发布 Release"
git add project.yml EdgeNotes.xcodeproj appcast.xml
git commit -m "Release v$VERSION"
git tag "v$VERSION"
git push origin HEAD:main "v$VERSION"
gh release create "v$VERSION" "$ZIP" --repo "$REPO" --title "EdgeNotes v$VERSION" --notes-file "${RELEASE_NOTES:-/dev/null}" --latest

echo "==> 完成：$URL"
