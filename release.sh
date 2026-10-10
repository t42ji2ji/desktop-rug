#!/bin/zsh
# 做出可以給別人下載的 build/DesktopRug.dmg：Developer ID 簽名、Apple 公證、staple。
# 公證用鑰匙圈裡的 notarytool 設定 away-blur（整個開發者帳號共用）
# 檔名不帶版本號，官網的下載連結 releases/latest/download/DesktopRug.dmg 才能一直有效
set -e
cd "${0:A:h}"
DMG=build/DesktopRug.dmg
RELEASE=1 ./build.sh
# 先公證 app 本身並 staple：拖進「應用程式」後第一次打開不用連網也能過 Gatekeeper
ditto -c -k --keepParent build/DesktopRug.app build/DesktopRug.zip
xcrun notarytool submit build/DesktopRug.zip --keychain-profile away-blur --wait
xcrun stapler staple build/DesktopRug.app
rm build/DesktopRug.zip
STAGE=build/dmg && rm -rf $STAGE && mkdir -p $STAGE
cp -R build/DesktopRug.app $STAGE/ && ln -s /Applications $STAGE/Applications
rm -f $DMG && hdiutil create -volname "Desktop Rug" -srcfolder $STAGE -format UDZO -quiet $DMG
codesign --force --timestamp --sign 40EE56946432E9A272F0B129ED83D5E843B5EAE8 $DMG
xcrun notarytool submit $DMG --keychain-profile away-blur --wait
xcrun stapler staple $DMG
spctl --assess --type open --context context:primary-signature -v $DMG
echo "done: $DMG"
