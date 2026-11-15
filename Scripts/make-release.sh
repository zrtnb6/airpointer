#!/bin/zsh
# 打一个通用二进制（Intel + Apple Silicon）的发布包：
#   build/AirPointer-<版本>-universal.dmg
# 用法：zsh Scripts/make-release.sh [版本号]
# 说明：本机构建用的是 adhoc 签名，DMG 里的 App 没有经过 Apple 公证，
#      首次打开需要右键「打开」，或执行 xattr -dr com.apple.quarantine。
set -euo pipefail
cd -- "${0:A:h}/.."

version="${1:-0.2-zh.1}"
app="build/AirPointer.app"
dmg="build/AirPointer-${version}-universal.dmg"
slices="$(mktemp -d)"
trap 'rm -rf "$slices"' EXIT

# macOS 14 是 Info.plist 里声明的最低版本；两个切片都按它编。
target_ver="14.0"

echo "== 编译 x86_64 切片 =="
clang -target x86_64-apple-macos${target_ver} -fobjc-arc -Wall -Wextra -Werror \
    -framework Foundation -framework CoreBluetooth -framework IOBluetooth \
    Sources/ClosedCaseMotion/CaseSustainedRenewal.m -o "$slices/ClosedCaseMotion.x86_64"
xcrun swiftc -target x86_64-apple-macos${target_ver} -swift-version 5 -O \
    Sources/ClosedCaseRestore/ClosedCaseRestore.swift -o "$slices/ClosedCaseRestore.x86_64" \
    -framework Foundation -framework CoreBluetooth -framework IOBluetooth
xcrun swiftc -target x86_64-apple-macos${target_ver} -swift-version 5 -O \
    Sources/AirPointer/**/*.swift -o "$slices/AirPointer.x86_64" \
    -framework AppKit -framework JavaScriptCore -framework QuartzCore \
    -framework ApplicationServices -framework Carbon -framework AVFoundation \
    -framework CoreAudio -framework CoreBluetooth

echo "== 编译 arm64 切片 =="
clang -target arm64-apple-macos${target_ver} -fobjc-arc -Wall -Wextra -Werror \
    -framework Foundation -framework CoreBluetooth -framework IOBluetooth \
    Sources/ClosedCaseMotion/CaseSustainedRenewal.m -o "$slices/ClosedCaseMotion.arm64"
xcrun swiftc -target arm64-apple-macos${target_ver} -swift-version 5 -O \
    Sources/ClosedCaseRestore/ClosedCaseRestore.swift -o "$slices/ClosedCaseRestore.arm64" \
    -framework Foundation -framework CoreBluetooth -framework IOBluetooth
xcrun swiftc -target arm64-apple-macos${target_ver} -swift-version 5 -O \
    Sources/AirPointer/**/*.swift -o "$slices/AirPointer.arm64" \
    -framework AppKit -framework JavaScriptCore -framework QuartzCore \
    -framework ApplicationServices -framework Carbon -framework AVFoundation \
    -framework CoreAudio -framework CoreBluetooth

echo "== 合并为通用二进制 =="
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
lipo -create -output "$app/Contents/MacOS/AirPointer" "$slices/AirPointer.x86_64" "$slices/AirPointer.arm64"
lipo -create -output "$app/Contents/Resources/ClosedCaseMotion.bin" "$slices/ClosedCaseMotion.x86_64" "$slices/ClosedCaseMotion.arm64"
lipo -create -output "$app/Contents/Resources/ClosedCaseRestore.bin" "$slices/ClosedCaseRestore.x86_64" "$slices/ClosedCaseRestore.arm64"
chmod +x "$app/Contents/MacOS/AirPointer" "$app/Contents/Resources/"*.bin

echo "== 拷贝资源 =="
cp Assets/CaseFront.png Assets/AppIcon.icns "$app/Contents/Resources/"
for frame in Assets/CaseLid/lid-*.png; do cp "$frame" "$app/Contents/Resources/Case${frame:t:r:s/lid/Lid/}.png"; done
cp Assets/TapClick/click.wav "$app/Contents/Resources/TapClick.wav"
cp Assets/NotchShimmer.wav "$app/Contents/Resources/NotchShimmer.wav"
cp Assets/TapClick/LICENSE-cuelume.txt "$app/Contents/Resources/LICENSE-cuelume.txt"
cp Sources/AirPointer/Session/Orientation.js "$app/Contents/Resources/ClosedCaseOrientation.js"

cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>AirPointer</string>
<key>CFBundleIdentifier</key><string>local.airpointer</string>
<key>CFBundleName</key><string>AirPointer</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.2</string>
<key>CFBundleVersion</key><string>2</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSBluetoothAlwaysUsageDescription</key><string>AirPointer 需要连接已配对的 AirPods，以便在合盖状态下持续获取动作数据。</string>
</dict></plist>
PLIST

# Apple Silicon 上未签名的 arm64 可执行文件无法运行，所以两个辅助程序也要 adhoc 签名，
# 然后再签整个 bundle，让资源封印把它们包含进去。
echo "== 签名（adhoc）=="
codesign --force --sign - --timestamp=none --identifier local.airpointer.closed-case-motion "$app/Contents/Resources/ClosedCaseMotion.bin"
codesign --force --sign - --timestamp=none --identifier local.airpointer.closed-case-restore "$app/Contents/Resources/ClosedCaseRestore.bin"
codesign --force --sign - --timestamp=none "$app"

echo "== 校验 =="
lipo -info "$app/Contents/MacOS/AirPointer"
lipo -info "$app/Contents/Resources/ClosedCaseMotion.bin"
codesign --verify --deep --strict --all-architectures "$app"
echo "签名与两个架构的封印校验通过"
"$app/Contents/MacOS/AirPointer" --self-test

echo "== 打包 DMG =="
stage="$(mktemp -d)"
trap 'rm -rf "$slices" "$stage"' EXIT
cp -R "$app" "$stage/AirPointer.app"
ln -s /Applications "$stage/Applications"
mkdir -p build
rm -f "$dmg"
hdiutil create -quiet -volname "AirPointer ${version}" -srcfolder "$stage" \
    -fs HFS+ -format UDZO -imagekey zlib-level=9 -ov "$dmg"

echo
echo "产物：$dmg"
ls -lh "$dmg" | awk '{print "体积："$5}'
shasum -a 256 "$dmg" | awk '{print "SHA256："$1}'
