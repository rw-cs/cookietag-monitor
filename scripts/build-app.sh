#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h:h}"
app_dir="$project_dir/dist/CookieTag Monitor.app"
build_dir="$project_dir/.build/release"
cache_dir="$project_dir/.build/cache/clang"
sdk_path="$(xcrun --sdk macosx --show-sdk-path)"

# Some macOS beta Command Line Tools briefly ship a compiler newer than the
# default SDK. Prefer the stable SDK already installed on those systems.
if [[ -d /Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk ]]; then
    sdk_path=/Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk
fi

cd "$project_dir"
mkdir -p "$build_dir" "$cache_dir"
CLANG_MODULE_CACHE_PATH="$cache_dir" swiftc \
    -O \
    -sdk "$sdk_path" \
    -target "$(uname -m)-apple-macosx13.0" \
    Sources/CookieTagMonitor/main.swift \
    -o "$build_dir/CookieTagMonitor" \
    -framework AppKit \
    -framework CoreBluetooth \
    -framework ServiceManagement \
    -framework UserNotifications

mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
cp "$build_dir/CookieTagMonitor" "$app_dir/Contents/MacOS/CookieTagMonitor"
cp "Resources/Info.plist" "$app_dir/Contents/Info.plist"
codesign --force --deep --sign - "$app_dir"

echo "$app_dir"
