#!/bin/zsh
# 編譯並打包成 build/DesktopRug.app（ad-hoc 簽章，Finder 自動化權限才會正常跳出）
set -e
cd "$(dirname "$0")"
swift build -c release
APP=build/DesktopRug.app
rm -rf $APP
mkdir -p $APP/Contents/MacOS $APP/Contents/Resources/patterns
cp .build/release/DesktopRug $APP/Contents/MacOS/
cp patterns/*.png $APP/Contents/Resources/patterns/ 2>/dev/null || true
cat > $APP/Contents/Info.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>app.dorara.desktoprug</string>
  <key>CFBundleName</key><string>Desktop Rug</string>
  <key>CFBundleExecutable</key><string>DesktopRug</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSAppleEventsUsageDescription</key><string>讀取桌面圖示的位置，讓地毯在圖示上隆起。</string>
</dict></plist>
PLIST
codesign -s - --force $APP
echo "built $APP"
