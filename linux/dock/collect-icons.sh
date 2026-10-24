#!/bin/bash
# 把桌面图标和常用应用的图标收集到 /tmp/dock-icons/，给 PC 上画效果图用（只读，不改平板）。
# 用法（root）：bash collect-icons.sh
H=/home/user
OUT=/tmp/dock-icons
rm -rf $OUT; mkdir -p $OUT

find_icon() {  # $1 = Icon= 的值
  local n="$1"
  if [ -f "$n" ]; then echo "$n"; return; fi
  for base in $H/.local/share/icons /var/lib/flatpak/exports/share/icons/hicolor $H/.local/share/flatpak/exports/share/icons/hicolor /snap/*/current/meta/gui /usr/share/icons/hicolor /usr/share/icons/breeze /usr/share/icons/breeze-dark; do
    [ -d "$base" ] || continue
    local f
    f=$(find "$base" \( -path '*scalable/apps/*' -o -path '*/apps/scalable/*' \) -name "$n.svg" 2>/dev/null | head -1)
    [ -n "$f" ] && { echo "$f"; return; }
    for s in 512 256 192 128 96 64 48; do
      f=$(find "$base" \( -path "*/${s}x${s}/apps/*" -o -path "*/apps/${s}/*" \) \( -name "$n.png" -o -name "$n.svg" \) 2>/dev/null | head -1)
      [ -n "$f" ] && { echo "$f"; return; }
    done
  done
  ls /usr/share/pixmaps/$n.* 2>/dev/null | head -1
}

for d in $H/Desktop/*.desktop /usr/share/applications/org.kde.dolphin.desktop /usr/share/applications/systemsettings.desktop \
         /usr/share/applications/org.kde.discover.desktop /usr/share/applications/org.kde.konsole.desktop; do
  [ -f "$d" ] || continue
  icon=$(sed -n 's/^Icon=//p' "$d" | head -1)
  f=$(find_icon "$icon")
  id=$(basename "$d" .desktop)
  if [ -n "$f" ]; then
    ext=${f##*.}
    cp "$f" "$OUT/$id.$ext"
    echo "$id <- $f"
  else
    echo "$id: icon '$icon' not found"
  fi
done
chmod -R a+r $OUT
