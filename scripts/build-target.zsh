# Sourced by the app, driver and installer build scripts.
architecture="${EZNTFS_ARCHITECTURE:-$(/usr/bin/uname -m)}"
deployment_target=14.0
artifact_suffix=''
target_swift_flags=()
bundle_build=''
monterey_fixture=no
case "${EZNTFS_MONTEREY:-0}:${EZNTFS_MONTEREY_PREVIEW:-0}" in
  0:0) ;;
  1:0|0:1)
    [[ "$architecture" == x86_64 ]] || { print -u2 -- "Monterey requires EZNTFS_ARCHITECTURE=x86_64."; exit 2; }
    deployment_target=12.7
    target_swift_flags=(-Xswiftc -DEZNTFS_MONTEREY)
    if [[ "${EZNTFS_MONTEREY_PREVIEW:-0}" == 1 ]]; then
      artifact_suffix=-Monterey-Preview2
      bundle_build=26
      monterey_fixture=yes
      target_swift_flags=(-Xswiftc -DEZNTFS_MONTEREY_PREVIEW)
    else
      artifact_suffix=-Monterey
    fi
    ;;
  *) print -u2 -- "Choose one Monterey build configuration."; exit 2 ;;
esac
[[ "$architecture" == arm64 || "$architecture" == x86_64 ]] || {
  print -u2 -- "Unsupported ezNTFS architecture: $architecture"
  exit 2
}
export EZNTFS_ARCHITECTURE="$architecture"
