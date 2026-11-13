#!/usr/bin/env bash
# Composes the App Store gallery from raw captures (tools/store_shots.sh):
# brand background (asphalt ink, siren glow), a headline in Outfit Black with
# an amber/red/blue rule, and the untouched gameplay frame below it with
# rounded corners. Picks: store/screenshots/picks.txt
#   order|device|raw file (under store/screenshots/raw)|HEADLINE
set -euo pipefail
cd "$(dirname "$0")/.."
FONT=assets/fonts/outfit_black.ttf
while IFS='|' read -r order dev raw head; do
  [[ -z "$order" || "$order" == \#* ]] && continue
  if [[ $dev == iphone69 ]]; then W=2868; H=1320; else W=2752; H=2064; fi
  out=store/screenshots/$dev; mkdir -p "$out"
  slug=$(echo "$head" | tr 'A-Z' 'a-z' | tr -cs 'a-z0-9' '_' | sed 's/_$//')
  band=$(( H * 19 / 100 ))            # headline band
  pad=$(( H * 4 / 100 ))
  ih=$(( H - band - pad ))            # gameplay frame height
  iw=$(( ih * W / H ))
  r=$(( H * 3 / 100 ))
  fs=$(( band * 46 / 100 ))
  tmp=$(mktemp -d)
  # Background: ink with red / blue glows low down.
  magick -size ${W}x${H} xc:'#0B0D12' \
    \( -size ${W}x${H} radial-gradient:'rgba(255,61,71,0.38)'-'rgba(255,61,71,0)' -geometry -$((W/3))+$((H/3)) \) -composite \
    \( -size ${W}x${H} radial-gradient:'rgba(61,125,255,0.38)'-'rgba(61,125,255,0)' -geometry +$((W/3))+$((H/3)) \) -composite \
    "$tmp/bg.png"
  # Gameplay frame, scaled, rounded corners, hairline edge.
  magick "store/screenshots/raw/$raw" -resize ${iw}x${ih}! \
    \( -size ${iw}x${ih} xc:none -fill white -draw "roundrectangle 0,0,$((iw-1)),$((ih-1)),$r,$r" \) \
    -alpha set -compose DstIn -composite "$tmp/shot.png"
  x=$(( (W - iw) / 2 )); y=$(( band ))
  magick "$tmp/bg.png" "$tmp/shot.png" -geometry +$x+$y -compose over -composite \
    -fill none -stroke 'rgba(255,255,255,0.14)' -strokewidth 3 -draw "roundrectangle $x,$y,$((x+iw-1)),$((y+ih-1)),$r,$r" \
    -stroke none -font "$FONT" -pointsize $fs -fill '#F4F5F7' -gravity north -annotate +0+$(( band * 22 / 100 )) "$head" \
    -gravity northwest \
    -fill '#FF3D47' -draw "rectangle $((W/2-120)),$((band*82/100)),$((W/2)),$((band*82/100+8))" \
    -fill '#3D7DFF' -draw "rectangle $((W/2)),$((band*82/100)),$((W/2+120)),$((band*82/100+8))" \
    -alpha off -depth 8 "$out/${order}_${slug}.png"
  rm -rf "$tmp"
  echo "$out/${order}_${slug}.png"
done < store/screenshots/picks.txt
