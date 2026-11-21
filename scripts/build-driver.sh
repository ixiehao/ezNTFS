#!/bin/zsh
set -euo pipefail

if (( $# != 2 )); then
  print -u2 -- "Usage: $0 <verified NTFS-3G release archive> <new output directory>"
  exit 2
fi
archive="${1:A}"
output="${2:A}"
version=2026.9.28
source_hash=350d9415c59f7c3fa74e23985ad2d56423c6a168337368f672e2e362d8f295c8
fuse_version=5.5.0
fuse_lib=/usr/local/lib/libfuse.2.dylib
fuse_bundle=/Library/Filesystems/macfuse.fs
fuse_signer='anchor apple generic and certificate leaf[subject.OU] = "3T5GSNBU6W"'
cpu="${EZNTFS_ARCHITECTURE:-$(/usr/bin/uname -m)}"
[[ "$cpu" == arm64 || "$cpu" == x86_64 ]] || {
  print -u2 -- "Unsupported ezNTFS architecture: $cpu"
  exit 2
}

[[ "$(/usr/bin/shasum -a 256 "$archive" | /usr/bin/cut -d ' ' -f 1)" == "$source_hash" ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$fuse_bundle/Contents/Info.plist")" == "$fuse_version" ]]
/usr/bin/codesign --verify --strict --arch "$cpu" -R="$fuse_signer" "$fuse_lib"
/usr/bin/codesign --verify --strict --arch "$cpu" -R="$fuse_signer" "$fuse_bundle/Contents/Resources/mount_macfuse"
/usr/bin/codesign --verify --strict --arch "$cpu" -R="$fuse_signer" "$fuse_bundle/Contents/Frameworks/MFMount.framework/Versions/A/MFMount"
work="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/ezntfs-driver.XXXXXXXX")"
trap 'rm -rf -- "$work"' EXIT
/usr/bin/tar -xzf "$archive" -C "$work"

# Build the NTFS code into the driver and omit gettext from its runtime dependencies.
original_script="${0:A}"
cd "$work/ntfs-3g-$version"
export MACOSX_DEPLOYMENT_TARGET=14.0
CC=/usr/bin/clang \
CFLAGS="-arch $cpu -g -O2" LDFLAGS="-arch $cpu -Wl,-headerpad_max_install_names" \
FUSE_CFLAGS="-I/usr/local/include/fuse -D_FILE_OFFSET_BITS=64" \
FUSE_LIBS="$fuse_lib" \
./configure --with-fuse=external --enable-static --disable-shared --disable-nls --disable-plugins
/usr/bin/make -j "$(/usr/sbin/sysctl -n hw.ncpu)"

minimum_os="$(/usr/bin/xcrun vtool -arch "$cpu" -show-build src/ntfs-3g | /usr/bin/awk '$1 == "minos" { print $2 }')"
if [[ "$minimum_os" != "$MACOSX_DEPLOYMENT_TARGET" ]]; then
  print -u2 -- "NTFS-3G was linked for macOS $minimum_os, expected $MACOSX_DEPLOYMENT_TARGET."
  exit 1
fi

mkdir -- "$output"
mkdir -p -- "$output/bin" "$output/lib" "$output/source"
/usr/bin/install -m 755 src/ntfs-3g "$output/bin/ntfs-3g"
/usr/bin/install -m 644 "$fuse_lib" "$output/lib/libfuse.2.dylib"
/usr/bin/codesign --verify --strict --arch "$cpu" -R="$fuse_signer" "$output/lib/libfuse.2.dylib"
/usr/bin/install_name_tool -change /usr/local/lib/libfuse.2.dylib '@loader_path/../lib/libfuse.2.dylib' "$output/bin/ntfs-3g"
identity="${EZNTFS_APP_SIGN_IDENTITY:--}"
sign_options=()
if [[ "$identity" != - ]]; then
  # The driver loads the verified library from the separately installed macFUSE.
  sign_options=(--options runtime --timestamp --entitlements "${original_script:h}/NTFS3G.entitlements")
fi
/usr/bin/codesign --force --sign "$identity" "${sign_options[@]}" --identifier local.ezntfs.ntfs3g "$output/bin/ntfs-3g"
/usr/bin/codesign --verify --strict "$output/bin/ntfs-3g"
/usr/bin/install -m 644 "$archive" "$output/source/ntfs-3g-$version.tgz"
/usr/bin/install -m 644 COPYING COPYING.LIB "$original_script" "${original_script:h}/NTFS3G.entitlements" "$output/source"
/usr/bin/python3 - "$output" "$version" "$fuse_version" "$cpu" <<'PY'
import hashlib
import plistlib
import subprocess
import sys
from pathlib import Path

output, version, fuse, architecture = sys.argv[1:]
root = Path(output)
driver = root / "bin/ntfs-3g"
lib = root / "lib/libfuse.2.dylib"
fuse_path = "@loader_path/../lib/libfuse.2.dylib"
fuse_framework = "/Library/Filesystems/macfuse.fs/Contents/Frameworks/MFMount.framework/Versions/A/MFMount"

for binary, expected, skip in [(driver, {fuse_path}, 1), (lib, {fuse_framework}, 2)]:
    dependencies = subprocess.check_output(
        ["/usr/bin/otool", "-arch", architecture, "-L", str(binary)], text=True
    ).splitlines()[skip:]
    loaded = {line.strip().split(" (", 1)[0] for line in dependencies}
    unapproved = {path for path in loaded if not path.startswith(("/usr/lib/", "/System/Library/"))} - expected
    if not expected <= loaded or unapproved:
        raise SystemExit(f"Unexpected dependency closure in {binary}: {sorted(loaded)}")

files = {str(path.relative_to(root)): hashlib.sha256(path.read_bytes()).hexdigest()
         for path in (driver, lib)}
with (root / "candidate.plist").open("wb") as stream:
    plistlib.dump({"build": f"{version}-{files['bin/ntfs-3g'][:12]}", "version": version,
                   "macFUSEVersion": fuse, "files": files}, stream)
PY
"$output/bin/ntfs-3g" --version
