#!/bin/bash
# 本机测试 iCloud 同步用的开发版（Apple Development 证书 + 开发描述文件）
# 用法：TEAM_ID=<团队ID> scripts/dev-icloud-build.sh   （描述文件放在 signing/EdgeNotes_Development.provisionprofile）
set -euo pipefail
cd "$(dirname "$0")/.."
TEAM_ID="${TEAM_ID:?请先 export TEAM_ID=<你的 Team ID>}"
PROFILE="${PROFILE:-signing/EdgeNotes_Development.provisionprofile}"
[ -f "$PROFILE" ] || { echo "没找到开发描述文件 $PROFILE"; exit 1; }
UUID_=$(security cms -D -i "$PROFILE" | plutil -extract UUID raw -)
mkdir -p "$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"
cp "$PROFILE" "$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles/$UUID_.provisionprofile"
xcodegen generate >/dev/null
xcodebuild -scheme EdgeNotes -configuration Debug -derivedDataPath build/dev-icloud \
  -clonedSourcePackagesDirPath build/SourcePackages \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="Apple Development" DEVELOPMENT_TEAM="$TEAM_ID" \
  CODE_SIGN_ENTITLEMENTS=EdgeNotes/EdgeNotes.dev.entitlements PROVISIONING_PROFILE_SPECIFIER="$UUID_" -quiet build
echo "完成：build/dev-icloud/Build/Products/Debug/EdgeNotes.app"
