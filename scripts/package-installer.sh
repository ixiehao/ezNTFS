#!/bin/zsh
set -euo pipefail

if (( $# != 1 )); then
  print -u2 -- "Usage: $0 <NTFS-3G release archive>"
  exit 2
fi
archive="${1:A}"
cd -- "${0:A:h:h}"
project="$(pwd -P)"
version="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Resources/Info.plist)"
source scripts/build-target.zsh
name="ezNTFS-$version-$architecture$artifact_suffix"
output="$project/dist/$name"
destination="$output/$name.pkg"
support='/Library/Application Support/ezNTFS'
[[ ! -L "$project/dist" && ! -L "$output" && ! -e "$destination" && ! -L "$destination" ]]
identity="${EZNTFS_APP_SIGN_IDENTITY:--}"
installer_options=()
if [[ -n "${EZNTFS_INSTALLER_SIGN_IDENTITY:-}" ]]; then
  # Build a fresh signed driver so its signature is covered by the published checksum.
  [[ "$identity" != - && -z "${EZNTFS_PREBUILT_DRIVER:-}" && "${EZNTFS_REUSE_INSTALLED_SERVICE:-0}" == 0 ]] || {
    print -u2 -- "Signed installers require an application signing identity and a fresh driver and service build."
    exit 1
  }
  installer_options=(--sign "$EZNTFS_INSTALLER_SIGN_IDENTITY" --timestamp)
fi
stage="$(mktemp -d "${TMPDIR:-/tmp}/ezntfs-package.XXXXXXXX")"
trap 'rm -rf -- "$stage"' EXIT
driver="$stage/driver"
enable_legacy_service=no
if [[ -n "$artifact_suffix" ]]; then
  enable_legacy_service=yes
fi
if [[ "$monterey_fixture" == yes ]]; then
  export EZNTFS_TEST_IMAGE_OUTPUT="$stage/EZNTFS-QA.img.gz"
fi
if [[ -n "${EZNTFS_PREBUILT_DRIVER:-}" ]]; then
  /usr/bin/ditto "$EZNTFS_PREBUILT_DRIVER" "$driver"
else
  scripts/build-driver.sh "$archive" "$driver"
fi
[[ "$(/usr/bin/lipo -archs "$driver/bin/ntfs-3g")" == "$architecture" ]] || {
  print -u2 -- "NTFS-3G does not match the package architecture: $architecture"
  exit 1
}
[[ "$(/usr/bin/xcrun vtool -show-build "$driver/bin/ntfs-3g" | /usr/bin/awk '$1 == "minos" { print $2 }')" == "$deployment_target" ]]
/usr/bin/codesign --verify --strict --arch "$architecture" "$driver/bin/ntfs-3g"
build="$(/usr/libexec/PlistBuddy -c 'Print :build' "$driver/candidate.plist")"
fuse="$(/usr/libexec/PlistBuddy -c 'Print :macFUSEVersion' "$driver/candidate.plist")"
[[ "$fuse" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]]
hash_file() { /usr/bin/shasum -a 256 "$1" | /usr/bin/cut -d ' ' -f 1; }
driver_hash="$(hash_file "$driver/bin/ntfs-3g")"
fuse_hash="$(hash_file "$driver/lib/libfuse.2.dylib")"
fuse_installer=Sources/EzNTFSCore/MacFUSEInstaller.swift
[[ "$fuse" == "$(/usr/bin/sed -nE 's/.*let version = "([^"]+)".*/\1/p' "$fuse_installer")" &&
   "$fuse_hash" == "$(/usr/bin/sed -nE 's/.*let librarySHA256 = "([^"]+)".*/\1/p' "$fuse_installer")" ]] || {
  print -u2 -- "The driver and macFUSE installer must use the same verified macFUSE build."
  exit 1
}

# Only the vendor library checksum is in the package. Installer takes its copy from macFUSE.
payload="$stage/payload"
mkdir -p "$payload$support/Driver"
mv "$driver" "$payload$support/Driver/$build"
rm -- "$payload$support/Driver/$build/lib/libfuse.2.dylib"

mkdir "$stage/scripts"
cp scripts/installer/{preinstall,postinstall} "$stage/scripts"
mkdir -p "$stage/usage" "$stage/module-cache"
cat > "$stage/usage/main.swift" <<'SWIFT'
import Darwin

guard CommandLine.arguments.count == 2 else { exit(2) }
exit(DriverUsage.inspectInstallation(under: CommandLine.arguments[1]).rawValue)
SWIFT
/usr/bin/swiftc -O -target "$architecture-apple-macosx$deployment_target" -module-cache-path "$stage/module-cache" \
  Sources/EzNTFSCore/DriverUsage.swift "$stage/usage/main.swift" -o "$stage/scripts/check-driver-usage"
sign_options=()
if [[ "$identity" != - ]]; then
  sign_options=(--options runtime --timestamp)
fi
/usr/bin/codesign --force --sign "$identity" "${sign_options[@]}" \
  --identifier local.ezntfs.driver-usage "$stage/scripts/check-driver-usage"
/usr/bin/codesign --verify --strict "$stage/scripts/check-driver-usage"
settings="$stage/scripts/settings"
cat > "$settings" <<SETTINGS
support='$support'
architecture='$architecture'
driver_build='$build'
driver_hash='$driver_hash'
fuse_version='$fuse'
enable_legacy_service='$enable_legacy_service'
export EZNTFS_FUSE_HASH='$fuse_hash'
SETTINGS

mkdir -p "$stage/components"
/usr/bin/ditto scripts/installer/Resources "$stage/resources"

build_product() {
  local component="$1" identifier="$2" package="$3"
  local reinstall_line='' reinstall_choice=''
  if [[ "${4:-}" == with-reinstall ]]; then
    reinstall_line='<line choice="local-reinstall"/>'
    reinstall_choice='<choice id="local-reinstall" visible="false"><pkg-ref id="local.ezntfs.reinstall-cache"/></choice><pkg-ref id="local.ezntfs.reinstall-cache">Reinstall.pkg</pkg-ref>'
  fi
  local definition="$stage/Distribution.xml"
  /usr/bin/sed -e "s|@ARCHITECTURE@|$architecture|g" \
    -e "s|@MINIMUM_OS@|$deployment_target|g" \
    -e "s|@MACFUSE_VERSION@|$fuse|g" \
    -e "s|@IDENTIFIER@|$identifier|g" -e "s|@VERSION@|$version|g" \
    -e "s|@COMPONENT@|$component|g" -e "s|@REINSTALL_LINE@|$reinstall_line|g" \
    -e "s|@REINSTALL_CHOICE@|$reinstall_choice|g" scripts/installer/Distribution.xml.in > "$definition"
  /usr/bin/productbuild --distribution "$definition" --package-path "$stage/components" \
    --resources "$stage/resources" "${installer_options[@]}" "$package"
}

print -r -- 'install_service=no' >> "$settings"
/usr/bin/pkgbuild --root "$payload" --scripts "$stage/scripts" --ownership recommended \
  --identifier local.ezntfs.driver --version "$version" --install-location / "$stage/components/Driver.pkg"
build_product Driver.pkg local.ezntfs.driver "$stage/ezNTFS-Driver.pkg"
EZNTFS_DRIVER_REPAIR_PKG="$stage/ezNTFS-Driver.pkg" \
  EZNTFS_TEST_IMAGE="${EZNTFS_TEST_IMAGE:-${EZNTFS_TEST_IMAGE_OUTPUT:-}}" scripts/build-app.sh

mkdir -p "$payload/Applications" "$payload/Library/LaunchDaemons" "$payload$support/Service.app/Contents/MacOS"
/usr/bin/ditto "$output/ezNTFS.app" "$payload/Applications/ezNTFS.app"
build_root="${EZNTFS_BUILD_ROOT:-$project/.build/package-$architecture-$deployment_target$artifact_suffix}"
export CLANG_MODULE_CACHE_PATH="$build_root/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$build_root/module-cache"
swift_options=(--triple "$architecture-apple-macosx$deployment_target"
               "${target_swift_flags[@]}"
               --scratch-path "$build_root" --cache-path "$build_root/swiftpm-cache"
               --config-path "$build_root/swiftpm-config" --security-path "$build_root/swiftpm-security")
if [[ "${EZNTFS_SWIFTPM_DISABLE_SANDBOX:-0}" == 1 ]]; then
  swift_options+=(--disable-sandbox)
fi
binaries="$(/usr/bin/swift build "${swift_options[@]}" --configuration release -debug-info-format none --show-bin-path)"
service="$payload$support/Service.app"
if [[ "${EZNTFS_REUSE_INSTALLED_SERVICE:-0}" == 1 ]]; then
  # Local app-only updates can keep the authorized daemon's exact identity.
  [[ "$identity" == "-" && "${#installer_options[@]}" == 0 && -z "$artifact_suffix" ]]
  installed_service="$support/Service.app"
  installed_executable="$installed_service/Contents/MacOS/ezntfs-service"
  [[ "$(/usr/bin/stat -f '%u' "$installed_executable")" == 0 ]]
  [[ "$(/usr/bin/lipo -archs "$installed_executable")" == "$architecture" ]]
  /usr/bin/cmp Resources/ServiceInfo.plist "$installed_service/Contents/Info.plist"
  /usr/bin/cmp Resources/local.ezntfs.mount.plist /Library/LaunchDaemons/local.ezntfs.mount.plist
  /usr/bin/codesign --verify --strict -R='identifier "local.ezntfs.mount"' "$installed_service"
  /usr/bin/ditto "$installed_service" "$service"
else
  /usr/bin/install -m 644 Resources/ServiceInfo.plist "$service/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Set LSMinimumSystemVersion $deployment_target" "$service/Contents/Info.plist"
  /usr/bin/install -m 755 "$binaries/ezntfs-service" "$service/Contents/MacOS/ezntfs-service"
  /usr/bin/codesign --force --sign "$identity" "${sign_options[@]}" "$service"
fi
[[ "$(/usr/bin/lipo -archs "$service/Contents/MacOS/ezntfs-service")" == "$architecture" ]]
/usr/bin/codesign --verify --strict "$service"

requirement() {
  # Pin exact code even for the local ad-hoc installation. Package upgrades replace these pins as a unit.
  local code_hash
  code_hash="$(/usr/bin/codesign -d --verbose=4 "$1" 2>&1 | /usr/bin/awk -F= '$1 == "CDHash" { print $2 }')"
  [[ "$code_hash" =~ '^[0-9a-f]{40}$' ]]
  print -r -- "identifier \"$2\" and cdhash H\"$code_hash\""
}
/usr/bin/python3 - "$payload$support/service.plist" \
  "$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$payload/Applications/ezNTFS.app/Contents/Info.plist")" \
  "$(requirement "$payload/Applications/ezNTFS.app" local.ezntfs.app)" \
  "$(requirement "$payload/Applications/ezNTFS.app/Contents/MacOS/ezntfs-tool" local.ezntfs.tool)" \
  "$(requirement "$service" local.ezntfs.mount)" <<'PY'
import plistlib
import sys

output, build, app, cli, daemon = sys.argv[1:]
if not all(requirement.endswith('"') and " and cdhash " in requirement for requirement in (app, cli, daemon)):
    raise SystemExit("Missing signed executable identity")
with open(output, "wb") as handle:
    plistlib.dump({"clientRequirement": f"({app}) or ({cli})",
                   "serviceRequirement": daemon, "appBuild": build}, handle)
PY
/usr/bin/install -m 644 Resources/local.ezntfs.mount.plist "$payload/Library/LaunchDaemons"
/usr/bin/plutil -lint "$payload/Library/LaunchDaemons/local.ezntfs.mount.plist" "$payload$support/service.plist"
print -r -- 'install_service=yes' >> "$settings"
/usr/bin/pkgbuild --analyze --root "$payload" "$stage/components.plist"
/usr/bin/python3 - "$stage/components.plist" <<'PY'
import plistlib
import sys
from pathlib import Path

manifest = Path(sys.argv[1])
components = plistlib.loads(manifest.read_bytes())
for component in components:
    component.update(BundleIsRelocatable=False, BundleOverwriteAction="upgrade", BundleVersionChecked=False)
manifest.write_bytes(plistlib.dumps(components))
PY
build_main_component() {
  /usr/bin/pkgbuild --root "$payload" --scripts "$stage/scripts" --component-plist "$stage/components.plist" \
    --ownership recommended --identifier local.ezntfs.installer --version "$version" --install-location / \
    "$stage/components/ezNTFS.pkg"
}

# Use a separate receipt so the local installer survives repairing the app and service.
build_main_component
mkdir -p "$stage/reinstall$support"
build_product ezNTFS.pkg local.ezntfs.installer "$stage/reinstall$support/ezNTFS-Reinstall.pkg"
/usr/bin/pkgbuild --root "$stage/reinstall" --ownership recommended --identifier local.ezntfs.reinstall-cache \
  --version "$version" --install-location / "$stage/components/Reinstall.pkg"
build_product ezNTFS.pkg local.ezntfs.installer "$stage/$name.pkg" with-reinstall

# The setup app is a separate bundle so it can verify macFUSE before opening the main PKG.
setup="$stage/Install ezNTFS.app"
/usr/bin/ditto "$output/ezNTFS.app" "$setup"
/bin/rm "$setup/Contents/MacOS/ezntfs-tool"
if [[ "$monterey_fixture" == yes ]]; then
  /bin/rm "$setup/Contents/Resources/EZNTFS-QA.img.gz"
fi
/usr/libexec/PlistBuddy -c 'Set CFBundleIdentifier local.ezntfs.setup' \
  -c 'Set CFBundleName Install ezNTFS' -c 'Set CFBundleDisplayName Install ezNTFS' \
  -c 'Add EZNTFSSetup bool true' "$setup/Contents/Info.plist"
/usr/bin/install -m 644 "$stage/$name.pkg" "$setup/Contents/Resources/ezNTFS-Install.pkg"
/usr/bin/codesign --force --sign "$identity" "${sign_options[@]}" "$setup"
/usr/bin/codesign --verify --deep --strict "$setup"
/usr/bin/ditto -c -k --keepParent "$setup" "$stage/$name-Setup.zip"

/usr/bin/xar -tf "$stage/$name.pkg"
/usr/bin/python3 scripts/publish-exclusive.py "$stage/$name.pkg" "$destination"
/usr/bin/python3 scripts/publish-exclusive.py "$stage/$name-Setup.zip" "$output/$name-Setup.zip"
/usr/bin/shasum -a 256 "$destination" "$output/$name-Setup.zip"
