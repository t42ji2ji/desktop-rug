#!/bin/zsh
# 編譯並打包成 build/DesktopRug.app
#   ./build.sh             開發版：ad-hoc 簽章（Finder 自動化權限才會正常跳出）
#   RELEASE=1 ./build.sh   發佈版：Developer ID＋hardened runtime＋時間戳（release.sh 用）
set -e
cd "$(dirname "$0")"
swift build -c release
APP=build/DesktopRug.app
rm -rf $APP
mkdir -p $APP/Contents/MacOS $APP/Contents/Resources/patterns $APP/Contents/Resources/cats
cp .build/release/DesktopRug $APP/Contents/MacOS/
cp patterns/*.png $APP/Contents/Resources/patterns/
cp cats/*.png cats/meta.json $APP/Contents/Resources/cats/
cp Resources/AppIcon.icns $APP/Contents/Resources/
# 系統權限提示的中文版
mkdir -p $APP/Contents/Resources/zh-Hant.lproj
cat > $APP/Contents/Resources/zh-Hant.lproj/InfoPlist.strings <<STRINGS
"NSAppleEventsUsageDescription" = "Desktop Rug 會讀取桌面圖示的位置，讓地毯在圖示堆上隆起。";
STRINGS
VERSION=1.0.1
cat > $APP/Contents/Info.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>app.dorara.desktoprug</string>
  <key>CFBundleName</key><string>Desktop Rug</string>
  <key>CFBundleDisplayName</key><string>Desktop Rug</string>
  <key>CFBundleExecutable</key><string>DesktopRug</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>2</string>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleLocalizations</key><array><string>en</string><string>zh-Hant</string></array>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSAppleEventsUsageDescription</key><string>Desktop Rug reads where your desktop icons are, so the rug bumps up over piles of files.</string>
</dict></plist>
PLIST
if [ -n "$RELEASE" ]; then
  codesign --force --options runtime --timestamp --entitlements DesktopRug.entitlements \
    --sign 40EE56946432E9A272F0B129ED83D5E843B5EAE8 $APP
  codesign --verify --deep --strict $APP
else
  codesign -s - --force $APP
fi
echo "built $APP"
