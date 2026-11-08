#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
dist=${1:?Usage: repackage.sh DIST_DIRECTORY}
shopt -s nullglob
images=("$dist"/*/*.AppImage)
if (( ${#images[@]} != 1 )); then
    printf 'Expected one AppImage under %s/*; found %s. Remove stale build outputs first.\n' \
        "$dist" "${#images[@]}" >&2
    exit 1
fi

input=$(realpath -- "${images[0]}")
output_dir=$(dirname -- "$input")
stage=$(mktemp -d "$output_dir/.appimage-stage.XXXXXX")
trap 'rm -rf -- "$stage"' EXIT

# A failed extraction must never fall back to a previous squashfs-root.
(
    cd -- "$stage"
    "$input" --appimage-extract > /dev/null
)
app_dir="$stage/squashfs-root"
cp -- "$script_dir/AppRun" "$app_dir/AppRun"
chmod -R a+rX "$app_dir"
chmod a+rx "$app_dir/AppRun"
sed -i '/^\[Desktop Entry\]/a StartupWMClass=app.hiddify.com' "$app_dir/hiddify.desktop"
# Use the host's libstdc++ for Arch Linux compatibility.
find "$app_dir/usr/lib" -name 'libstdc++.so.6' -delete

rebuilt="$stage/Hiddify.AppImage"
ARCH=x86_64 appimagetool --no-appstream "$app_dir" "$rebuilt"
test -s "$rebuilt"

portable_name=hiddify-linux-appimage
mkdir -p "$stage/$portable_name/Hiddify.AppImage.home"
cp -p -- "$rebuilt" "$stage/$portable_name/Hiddify.AppImage"
tar -czf "$stage/$portable_name.tar.gz" -C "$stage" "$portable_name"

# Keep the original until both the rebuilt image and portable archive exist.
mv -f -- "$rebuilt" "$output_dir/Hiddify.AppImage"
mv -f -- "$stage/$portable_name.tar.gz" "$output_dir/$portable_name.tar.gz"
if [[ "$input" != "$output_dir/Hiddify.AppImage" ]]; then
    rm -- "$input"
fi
printf 'AppImage and portable archive created in %s\n' "$output_dir"
