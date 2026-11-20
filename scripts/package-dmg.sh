#!/bin/zsh
set -euo pipefail

cd -- "${0:A:h:h}"
version="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Resources/Info.plist)"
architecture="$(/usr/bin/uname -m)"
name="ezNTFS-$version-$architecture"
project="$(pwd -P)"
output="$project/dist/$name"
app="$output/ezNTFS.app"
destination="$output/$name.dmg"
if [[ -L "$project/dist" || -L "$output" || -L "$app" || -e "$destination" || -L "$destination" ]]; then
  print -u2 -- "目标路径是符号链接，或本版本 DMG 已存在。"
  exit 1
fi
[[ "${output:A}" == "$output" ]]
/usr/bin/codesign --verify --deep --strict "$app"

dmg_python="${EZNTFS_DMG_PYTHON:-$project/.build/dmg-tools/bin/python3}"
if ! "$dmg_python" -c 'import dmgbuild, ds_store, mac_alias' 2>/dev/null; then
  print -u2 -- "打包工具缺失。请参见 docs/DEVELOPMENT.md 配置 DMG 工具环境。"
  exit 1
fi

staging="$(mktemp -d "$output/.dmg.XXXXXXXX")"
mountpoint="$staging/verify"
cleanup() {
  if /sbin/mount | /usr/bin/grep -Fq " on $mountpoint ("; then
    if ! /usr/bin/hdiutil detach "$mountpoint" -quiet; then
      print -u2 -- "暂存镜像仍在挂载，已保留 $staging。"
      return
    fi
  fi
  if [[ -d "$staging" && ! -L "$staging" && "${staging:A}" == "$output"/.dmg.* ]]; then
    rm -rf -- "$staging"
  fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

mkdir -p -- "$project/.build/module-cache" "$mountpoint"
/usr/bin/swift -module-cache-path "$project/.build/module-cache" scripts/create-dmg-background.swift "$staging/background.png"
"$dmg_python" -m dmgbuild -s scripts/dmg-layout.py -D app="$app" -D background="$staging/background.png" \
  "ezNTFS $version" "$staging/$name.dmg"
/usr/bin/hdiutil verify "$staging/$name.dmg"
/usr/bin/hdiutil attach -readonly -noverify -noautoopen -mountpoint "$mountpoint" "$staging/$name.dmg" >/dev/null
"$dmg_python" scripts/dmg-layout.py "$mountpoint"
/usr/bin/codesign --verify --deep --strict "$mountpoint/ezNTFS.app"
for executable in ezNTFS ezntfs-tool; do
  [[ "$(/usr/bin/lipo -archs "$mountpoint/ezNTFS.app/Contents/MacOS/$executable")" == "$architecture" ]]
done
/usr/bin/hdiutil detach "$mountpoint" -quiet
/usr/bin/python3 scripts/publish-exclusive.py "$staging/$name.dmg" "$destination"
/usr/bin/shasum -a 256 "$destination"
