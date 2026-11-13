#!/usr/bin/env bash
# App Store screenshots: genuine gameplay (autopilot, HUD and touch controls
# as shipped) rendered at the exact store sizes under Xvfb, several moments
# per run (fixed seeds). Picks and headlines: tools/store_compose.sh.
#   tools/store_shots.sh [iphone69|ipad13|all] [shot-name...]
set -euo pipefail
cd "$(dirname "$0")/.."
which=${1:-all}; shift || true
only=("$@")
S="--touch --notutorial --quality=2 --save=user://store_save.json"
declare -A SHOTS=(
  [swarm]="13,14,15,16,17,18,19 --play --bot --heat=6 --time=18.6 --seed=11"
  [bridge]="7,9,11,13 --play --bot --heat=3 --at=0,-21,-90 --time=17 --seed=4"
  [jump]="2.0,2.1,2.2,2.3,2.4 --play --bot --heat=3 --scenario=ramp --ramp=5 --time=16 --seed=3"
  [sky]="5,6,7,9 --play --bot --mode=sky --time=18 --seed=2"
  [roofs]="12,15,18,21 --play --bot --mode=rooftops --time=12 --seed=2"
  [garage]="3 --menu=garage --garage-tab=workshop --time=12 --seed=1"
)
render() {  # device WxH name
  local dev=$1 res=$2 name=$3 w=${2%x*} h=${2#*x}
  local spec=${SHOTS[$name]} times=${SHOTS[$name]%% *} args=${SHOTS[$name]#* }
  mkdir -p store/screenshots/raw/$dev
  rm -f store/screenshots/raw/$dev/${name}_*.png
  timeout 2400 xvfb-run -a -s "-screen 0 $((w + 64))x$((h + 64))x24" godot --rendering-method mobile --resolution "$res" \
    --fixed-fps 30 -- --shot="$PWD/store/screenshots/raw/$dev/${name}.png" --shot-at="$times" $args $S 2>&1 \
    | grep -E "SCREENSHOT|SCRIPT ERROR" | sed 's|.*/raw/||' || true
}
for dev in iphone69 ipad13; do
  [[ $which != all && $which != $dev ]] && continue
  res=$([[ $dev == iphone69 ]] && echo 2868x1320 || echo 2752x2064)
  for name in "${!SHOTS[@]}"; do
    [[ ${#only[@]} -gt 0 && ! " ${only[*]} " =~ " $name " ]] && continue
    render $dev $res $name &
    while (( $(jobs -rp | wc -l) >= 3 )); do wait -n; done
  done
done
wait
