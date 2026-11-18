#!/usr/bin/env bash
# 把编译好的 dylib 注入到已有的迅雷 IPA，产出可直接丢进 TrollStore 的 .tipa
#
# 依赖：insert_dylib (https://github.com/Tyilo/insert_dylib)、ldid、unzip
#   brew install ldid
#   git clone https://github.com/Tyilo/insert_dylib && (cd insert_dylib && xcodebuild -project insert_dylib.xcodeproj -configuration Release) \
#     && sudo cp insert_dylib/build/Release/insert_dylib /usr/local/bin/
#
# 用法：./scripts/make_tipa.sh <迅雷.ipa> [deb包或dylib路径] [输出名]
set -euo pipefail

IPA="${1:?用法: make_tipa.sh <ipa> [deb|dylib] [outname]}"
SRC="${2:-}"
OUT="${3:-XunleiEnhance.tipa}"
DYLIB_NAME="XunleiEnhance.dylib"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "==> 解包 $(basename "$IPA")"
unzip -q "$IPA" -d "$WORK/extract"
APP="$(find "$WORK/extract/Payload" -maxdepth 1 -name '*.app' | head -1)"
[ -d "$APP" ] || { echo "找不到 .app"; exit 1; }
EXEC_NAME="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$APP/Info.plist")"
EXEC="$APP/$EXEC_NAME"
echo "    app: $(basename "$APP")  可执行文件: $EXEC_NAME"

# 取 dylib
if [ -z "$SRC" ]; then
  SRC="$(ls -t packages/*.deb 2>/dev/null | head -1 || true)"
fi
[ -n "$SRC" ] || { echo "没找到 deb，请先 make package"; exit 1; }

if [[ "$SRC" == *.deb ]]; then
  echo "==> 从 deb 提取 dylib"
  SRC_ABS="$(cd "$(dirname "$SRC")" && pwd)/$(basename "$SRC")"
  mkdir -p "$WORK/deb"
  ( cd "$WORK/deb" && ar x "$SRC_ABS" )
  DATA_TAR="$(ls "$WORK"/deb/data.tar* | head -1)"
  REL="$(tar -tf "$DATA_TAR" | grep -m1 "MobileSubstrate/DynamicLibraries/$DYLIB_NAME")"
  [ -n "$REL" ] || { echo "deb 里没有 $DYLIB_NAME"; exit 1; }
  tar -xf "$DATA_TAR" -C "$WORK/deb" "$REL"
  cp "$WORK/deb/$REL" "$WORK/$DYLIB_NAME"
else
  cp "$SRC" "$WORK/$DYLIB_NAME"
fi
echo "    dylib: $(ls -l "$WORK/$DYLIB_NAME" | awk '{print $5}') bytes"

echo "==> 注入 LC_LOAD_DYLIB"
mkdir -p "$APP/Frameworks"
cp "$WORK/$DYLIB_NAME" "$APP/Frameworks/$DYLIB_NAME"
insert_dylib --inplace --add-load-path --weak \
  "@executable_path/Frameworks/$DYLIB_NAME" "$EXEC" >/dev/null

echo "==> 重新签名"
ENTS="$WORK/ents.plist"
if ldid -e "$EXEC" > "$ENTS" 2>/dev/null && [ -s "$ENTS" ]; then
  ldid -S"$ENTS" "$EXEC"
else
  ldid -S "$EXEC"
fi
ldid -S "$APP/Frameworks/$DYLIB_NAME"

echo "==> 打包 $OUT"
rm -rf "$WORK/extract/Payload/$(basename "$APP")/_CodeSignature" 2>/dev/null || true
( cd "$WORK/extract" && zip -qry "$OLDPWD/$OUT" Payload )
echo "完成: $OLDPWD/$OUT"
