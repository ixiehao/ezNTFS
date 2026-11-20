#!/bin/zsh
set -euo pipefail

cd -- "${0:A:h:h}"
project="$(pwd -P)"
build_root="${EZNTFS_BUILD_ROOT:-$project/.build}"
mkdir -p -- "$build_root"
cache="$build_root/module-cache"
mkdir -p -- "$cache" "$build_root/swiftpm-cache" "$build_root/swiftpm-config" "$build_root/swiftpm-security"
export CLANG_MODULE_CACHE_PATH="$cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$cache"
swift_options=(--scratch-path "$build_root" --cache-path "$build_root/swiftpm-cache"
               --config-path "$build_root/swiftpm-config" --security-path "$build_root/swiftpm-security")
if [[ "${EZNTFS_SWIFTPM_DISABLE_SANDBOX:-0}" == 1 ]]; then
  swift_options+=(--disable-sandbox)
fi

/usr/bin/swift build "${swift_options[@]}" --configuration release -debug-info-format none
binaries="$(/usr/bin/swift build "${swift_options[@]}" --configuration release -debug-info-format none --show-bin-path)"
version="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Resources/Info.plist)"
architecture="$(/usr/bin/uname -m)"
output="$project/dist/ezNTFS-$version-$architecture"
destination="$output/ezNTFS.app"
if [[ -L "$project/dist" || -L "$output" || -e "$destination" || -L "$destination" ]]; then
  print -u2 -- "目标目录是符号链接，或本版本 App 已存在。"
  exit 1
fi
mkdir -p -- "$output"
[[ "${output:A}" == "$output" ]]
staging="$(mktemp -d "$output/.build.XXXXXXXX")"
cleanup() {
  if [[ -d "$staging" && ! -L "$staging" && "${staging:A}" == "$output"/.build.* ]]; then
    rm -rf -- "$staging"
  fi
}
trap cleanup EXIT
app="$staging/ezNTFS.app"
resources="$app/Contents/Resources"
mkdir -p -- "$app/Contents/MacOS" "$resources"
/usr/bin/xcrun actool --compile "$resources" --platform macosx --minimum-deployment-target 14.0 Resources/Tabler.xcassets Resources/Brand.xcassets
/usr/bin/install -m 644 Resources/Tabler/LICENSE "$resources/Tabler-Icons-LICENSE.txt"
/usr/bin/install -m 644 LICENSE "$resources/ezNTFS-LICENSE.txt"
for localization in Sources/EzNTFSApp/Resources/*.lproj; do
  /usr/bin/ditto "$localization" "$resources/${localization:t}"
done

iconset="$staging/AppIcon.iconset"
mkdir -- "$iconset"
/usr/bin/sips -s format png Resources/Brand/AppIcon.svg --out "$staging/icon.png" >/dev/null
for size in 16 32 128 256 512; do
  /usr/bin/sips -z "$size" "$size" "$staging/icon.png" --out "$iconset/icon_${size}x${size}.png" >/dev/null
  /usr/bin/sips -z "$((size * 2))" "$((size * 2))" "$staging/icon.png" --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
done
/usr/bin/sips -s format png Resources/Brand/AppIcon-32.svg --out "$iconset/icon_32x32.png" >/dev/null
/bin/cp -- "$iconset/icon_32x32.png" "$iconset/icon_16x16@2x.png"
/usr/bin/iconutil -c icns "$iconset" -o "$resources/AppIcon.icns"
/usr/bin/install -m 644 Resources/Info.plist "$app/Contents/Info.plist"
/usr/bin/install -m 755 "$binaries/ezNTFS" "$app/Contents/MacOS/ezNTFS"
/usr/bin/install -m 755 "$binaries/ezntfs-tool" "$app/Contents/MacOS/ezntfs-tool"
if [[ -n "${EZNTFS_DRIVER_REPAIR_PKG:-}" ]]; then
  /usr/bin/install -m 644 "$EZNTFS_DRIVER_REPAIR_PKG" "$resources/ezNTFS-Driver.pkg"
fi
identity="${EZNTFS_APP_SIGN_IDENTITY:--}"
sign_options=()
if [[ "$identity" != "-" ]]; then
  sign_options=(--options runtime --timestamp)
fi
/usr/bin/codesign --force --sign "$identity" "${sign_options[@]}" --identifier local.ezntfs.tool "$app/Contents/MacOS/ezntfs-tool"
/usr/bin/codesign --force --sign "$identity" "${sign_options[@]}" "$app"
/usr/bin/codesign --verify --deep --strict "$app"

/usr/bin/python3 scripts/publish-exclusive.py "$app" "$destination"
print -r -- "$destination"
