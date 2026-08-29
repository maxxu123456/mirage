#!/bin/bash
# Assembles Mirage.app from the SwiftPM build.
#
# SwiftPM produces a bare executable; macOS needs a bundle for a menu-bar app
# (LSUIElement, an icon, a bundle identifier). The Homebrew glslang dylibs are
# copied into Contents/Frameworks and their install names rewritten so the app
# runs on a Mac without Homebrew.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="${1:-release}"
APP="$REPO/build/Mirage.app"
BUNDLE_ID="com.mirage.wallpaper"
VERSION="0.1.0"

echo "==> Building ($CONFIG)"
cd "$REPO"
swift build -c "$CONFIG" --product Mirage

BIN="$(swift build -c "$CONFIG" --product Mirage --show-bin-path)/Mirage"
[ -x "$BIN" ] || { echo "no binary at $BIN"; exit 1; }

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN" "$APP/Contents/MacOS/Mirage"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key><string>en</string>
	<key>CFBundleExecutable</key><string>Mirage</string>
	<key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
	<key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
	<key>CFBundleName</key><string>Mirage</string>
	<key>CFBundleDisplayName</key><string>Mirage</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>CFBundleShortVersionString</key><string>$VERSION</string>
	<key>CFBundleVersion</key><string>$VERSION</string>
	<key>LSMinimumSystemVersion</key><string>14.0</string>
	<key>LSUIElement</key><true/>
	<key>NSHighResolutionCapable</key><true/>
	<key>NSSupportsAutomaticGraphicsSwitching</key><true/>
	<key>NSHumanReadableCopyright</key><string>Mirage</string>
</dict>
</plist>
PLIST

echo "APPL????" > "$APP/Contents/PkgInfo"

# Bundled Wallpaper Engine built-ins we ship ourselves (the copy command shaders).
if [ -d "$REPO/Resources/WEAssets" ]; then
	cp -R "$REPO/Resources/WEAssets" "$APP/Contents/Resources/WEAssets"
fi

echo "==> Bundling dylibs"
# Collect the non-system dependencies transitively.
collect() {
	otool -L "$1" | tail -n +2 | awk '{print $1}' \
		| grep -E '^(/opt/homebrew|/usr/local)' || true
}

# macOS ships bash 3.2 (no associative arrays), so drive the closure through a
# work file: keep copying dependencies until a pass adds nothing new.
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
collect "$APP/Contents/MacOS/Mirage" > "$WORK/todo"

while [ -s "$WORK/todo" ]; do
	: > "$WORK/next"
	while IFS= read -r lib; do
		[ -z "$lib" ] && continue
		base="$(basename "$lib")"
		if [ -e "$APP/Contents/Frameworks/$base" ]; then continue; fi
		real="$lib"
		if [ ! -f "$real" ]; then real="$(readlink "$lib" 2>/dev/null || echo "$lib")"; fi
		if [ ! -f "$real" ]; then echo "    ! missing $lib"; continue; fi
		cp -L "$real" "$APP/Contents/Frameworks/$base"
		chmod u+w "$APP/Contents/Frameworks/$base"
		echo "    + $base"
		collect "$APP/Contents/Frameworks/$base" >> "$WORK/next"
	done < "$WORK/todo"
	sort -u "$WORK/next" > "$WORK/todo"
done

echo "==> Rewriting install names"
install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/Mirage" 2>/dev/null || true
for path in "$APP/Contents/Frameworks/"*.dylib; do
	[ -e "$path" ] || continue
	base="$(basename "$path")"
	install_name_tool -id "@rpath/$base" "$path"
	# Point every consumer at @rpath.
	for consumer in "$APP/Contents/MacOS/Mirage" "$APP/Contents/Frameworks/"*.dylib; do
		[ -e "$consumer" ] || continue
		while IFS= read -r dep; do
			if [ "$(basename "$dep")" = "$base" ]; then
				install_name_tool -change "$dep" "@rpath/$base" "$consumer" 2>/dev/null || true
			fi
		done < <(otool -L "$consumer" | tail -n +2 | awk '{print $1}' | grep -E '^(/opt/homebrew|/usr/local)' || true)
	done
done

echo "==> Signing (ad-hoc)"
codesign --force --sign - --timestamp=none "$APP/Contents/Frameworks/"*.dylib 2>/dev/null || true
codesign --force --sign - --timestamp=none "$APP"

echo "==> Verifying"
if otool -L "$APP/Contents/MacOS/Mirage" | grep -qE '/opt/homebrew|/usr/local'; then
	echo "    ! still references Homebrew paths:"
	otool -L "$APP/Contents/MacOS/Mirage" | grep -E '/opt/homebrew|/usr/local'
else
	echo "    binary is relocatable"
fi

echo
echo "Built $APP"
echo "Run it with:  open \"$APP\""
