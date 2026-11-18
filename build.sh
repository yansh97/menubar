#!/bin/bash
set -eu

cd "$(dirname "$0")"

work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

min_macos="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' Resources/Info.plist)"
icon_name="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconFile' Resources/Info.plist)"

build_args=(-c release --scratch-path "$PWD/build" --triple "arm64-apple-macosx$min_macos")
xcrun swift build "${build_args[@]}"
binary_dir="$(xcrun swift build "${build_args[@]}" --show-bin-path)"

app_dir="$work_dir/MenuBar.app"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
xcrun strip -S -o "$app_dir/Contents/MacOS/MenuBar" "$binary_dir/MenuBar"
cp Resources/Info.plist "$app_dir/Contents/Info.plist"
cp "Resources/$icon_name" LICENSE "$app_dir/Contents/Resources/"

codesign --force --sign - "$app_dir"
codesign --verify --deep --strict --verbose=1 "$app_dir"

mkdir -p dist
rm -rf dist/MenuBar.app
mv "$app_dir" dist/MenuBar.app
echo "Built $PWD/dist/MenuBar.app"
