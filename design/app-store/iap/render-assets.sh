#!/bin/sh
set -eu
cd "$(dirname "$0")"

mkdir -p final
magick _original/icloud-sync-generated.png -resize 1024x1024 \
  -background white -alpha remove -alpha off -colorspace sRGB \
  -units PixelsPerInch -density 72 \
  -define png:color-type=2 final/icloud-sync-promotional-1024.png

# Remove only the capture host's title bar and excess blank window space.
magick _original/mac-paywall-window.png -crop 1120x730+0+64 +repage \
  -background '#1f1f1f' -alpha remove -alpha off -colorspace sRGB \
  -define png:color-type=2 _original/mac-paywall-cropped.png
magick -size 1440x900 canvas:'#f3f5f6' \
  _original/mac-paywall-cropped.png -geometry +160+85 -composite \
  -alpha off -colorspace sRGB -define png:color-type=2 \
  final/mac-icloud-sync-review.png
magick _original/ios-paywall.png -alpha off -colorspace sRGB \
  -define png:color-type=2 final/ios-icloud-sync-review.png

# One shared IAP record can use this reviewer-only comparison of both platforms.
magick -size 2880x1800 canvas:'#f3f5f6' \
  -font /System/Library/Fonts/SFNS.ttf -fill '#171b20' \
  -pointsize 64 -annotate +100+120 'iCloud Sync' \
  -pointsize 28 -fill '#525c63' \
  -annotate +100+176 'Copied - one-time in-app purchase' \
  -pointsize 36 -fill '#171b20' \
  -annotate +100+490 'macOS' -annotate +1860+140 'iOS' \
  \( _original/mac-paywall-cropped.png -resize 1344x876 \) \
  -geometry +100+530 -composite \
  \( final/ios-icloud-sync-review.png -resize 720x1564 \) \
  -geometry +1860+180 -composite \
  -alpha off -colorspace sRGB -define png:color-type=2 \
  final/mac-ios-icloud-sync-review.png

magick identify -format '%f: %wx%h, %[channels]\n' final/*.png
