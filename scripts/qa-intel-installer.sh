#!/bin/bash
set -euo pipefail

[[ "${RUNNER_ENVIRONMENT:-}" = github-hosted && "${RUNNER_ARCH:-}" = X64 && "$(uname -m)" = x86_64 ]]
work="$RUNNER_TEMP/ezntfs-intel"
support='/Library/Application Support/ezNTFS'
archive="$work/ntfs-3g_ntfsprogs-2026.9.28.tgz"
version=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Resources/Info.plist)
package="$PWD/dist/ezNTFS-$version-x86_64/ezNTFS-$version-x86_64.pkg"
cli=/Applications/ezNTFS.app/Contents/MacOS/ezntfs-tool
fuse='/Library/Filesystems/macfuse.fs'
vendor_hash=92c21ef2db4199bcf5bddc8e6efb57b23ecb9715f74ab38cba2c77ab226d3830
ntfs_hash=350d9415c59f7c3fa74e23985ad2d56423c6a168337368f672e2e362d8f295c8

prepare() {
    test ! -e "$support"
    test ! -e /Applications/ezNTFS.app
    test ! -e "$fuse"
    mkdir "$work"
    curl -fLSs --retry 3 https://github.com/macfuse/macfuse/releases/download/macfuse-5.5.0/macfuse-5.5.0.dmg -o "$work/macfuse.dmg"
    printf '%s  %s\n' "$vendor_hash" "$work/macfuse.dmg" | shasum -a 256 -c
    curl -fLSs --retry 3 https://tuxera.com/opensource/ntfs-3g_ntfsprogs-2026.9.28.tgz -o "$archive"
    printf '%s  %s\n' "$ntfs_hash" "$archive" | shasum -a 256 -c
    mountpoint="$work/macfuse"
    /usr/bin/hdiutil attach -nobrowse -readonly -mountpoint "$mountpoint" "$work/macfuse.dmg"
    trap '/usr/bin/hdiutil detach "$mountpoint"' EXIT
    vendor_package="$(find "$mountpoint" -maxdepth 2 -type f -name '*.pkg' -print -quit)"
    test -f "$vendor_package"
    /usr/sbin/pkgutil --check-signature "$vendor_package"
    sudo /usr/sbin/installer -pkg "$vendor_package" -target /
    test "$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$fuse/Contents/Info.plist")" = 5.5.0
    EZNTFS_ARCHITECTURE=x86_64 EZNTFS_APP_SIGN_IDENTITY=- scripts/package-installer.sh "$archive" >"$work/package.log" 2>&1 || {
        tail -100 "$work/package.log"
        return 1
    }
    tail -18 "$work/package.log"
}

verify_service() {
    local report
    report="$("$cli" dependencies)"
    printf '%s\n' "$report"
    grep -Fx $'macFUSE\t5.5.0' <<< "$report"
    grep -Fx $'NTFS-3G\t2026.9.28' <<< "$report"
    grep -Fx $'挂载服务\t已连接' <<< "$report"
}

install_package() {
    /usr/sbin/installer -showChoicesXML -pkg "$package" -target / > "$work/choices.plist"
    /usr/bin/plutil -lint "$work/choices.plist"
    # The VM begins with no installed ezNTFS service or real NTFS disks.
    sudo /usr/sbin/installer -verboseR -pkg "$package" -target /
    /usr/bin/codesign --verify --deep --strict /Applications/ezNTFS.app
    /usr/bin/codesign --verify --strict "$support/Service.app"
    sudo /bin/launchctl print system/local.ezntfs.mount
    verify_service
    sudo /usr/sbin/installer -pkg "$package" -target /
    verify_service
    sudo /usr/sbin/installer -pkg /Applications/ezNTFS.app/Contents/Resources/ezNTFS-Driver.pkg -target /
    verify_service
    local driver_build
    driver_build=$(/usr/libexec/PlistBuddy -c 'Print build' "$support/Driver/installed.plist")
    for binary in /Applications/ezNTFS.app/Contents/MacOS/ezNTFS "$cli" \
        "$support/Service.app/Contents/MacOS/ezntfs-service" "$support/Driver/$driver_build/bin/ntfs-3g"; do
        test "$(/usr/bin/lipo -archs "$binary")" = x86_64
        test "$(xcrun vtool -show-build "$binary" | awk '$1 == "minos" {print $2}')" = 14.0
        /usr/bin/codesign --verify --strict --arch x86_64 "$binary"
    done
}

verify_image() {
    local fixture="$work/fixture.img"
    test ! -e "$fixture"
    tar -xzf "$archive" -C "$work"
    (
        cd "$work/ntfs-3g-2026.9.28"
        CC=/usr/bin/clang FUSE_CFLAGS='-I/usr/local/include/fuse -D_FILE_OFFSET_BITS=64' \
            FUSE_LIBS=/usr/local/lib/libfuse.2.dylib \
            ./configure --with-fuse=external --enable-static --disable-shared --disable-nls --disable-plugins &&
        /usr/bin/make -j 4 -C libntfs-3g &&
        /usr/bin/make -j 4 -C ntfsprogs mkntfs
    ) > "$work/mkntfs-build.log" 2>&1 || { tail -70 "$work/mkntfs-build.log"; return 1; }
    truncate -s 768m "$fixture"
    "$work/ntfs-3g-2026.9.28/ntfsprogs/mkntfs" -F -Q -s 512 -L EZNTFS-INTEL-QA "$fixture"
    shasum -a 256 "$fixture" > "$work/fixture.sha256"
    local result=0
    "$cli" verify-image "$fixture" || result=$?
    shasum -a 256 -c "$work/fixture.sha256"
    if [[ "$result" != 0 ]]; then
        /usr/bin/kmutil showloaded 2>&1 | grep -i 'macfuse\|error' || true
        /usr/bin/log show --last 3m --style compact --predicate '(process == "kernelmanagerd" OR process == "mount_macfuse") AND (eventMessage CONTAINS[c] "macfuse" OR eventMessage CONTAINS[c] "approval")' | tail -50
        return "$result"
    fi
    EZNTFS_TEST_IMAGE="$fixture" swift test
    shasum -a 256 -c "$work/fixture.sha256"
}

case "${1:-}" in
    prepare) prepare ;;
    install) install_package ;;
    image) verify_image ;;
    *) exit 2 ;;
esac
