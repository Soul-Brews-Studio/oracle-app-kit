#!/usr/bin/env zsh
# check.sh <Name> [--no-launch] [--shots] [--deep] [--ios]
# The acceptance rows of /oracle-app for an app built from this kit and installed in /Applications.
# Prints ✓/✗ per row; every ✗ carries the command that fixes or narrows it. Exit 0 = all green.
#   --no-launch  do not relaunch the app (a human is using it); launch-dependent rows read the running copy
#   --shots      window screenshots of status / memory / map into build/shots/   (needs Screen Recording)
#   --deep       Memory + Map: -memoryAction batch / layout, then read the app's log   (loads the model; minutes)
#   --ios        compile the iOS target (no device, no signing)
set -u
N=${1:?usage: check.sh <Name> [--no-launch] [--shots] [--deep] [--ios]}; shift
LAUNCH=1 SHOTS=0 DEEP=0 IOS=0
for a in "$@"; do case $a in --no-launch) LAUNCH=0;; --shots) SHOTS=1;; --deep) DEEP=1;; --ios) IOS=1;; esac; done
K=${0:A:h}/../..; K=${K:A}; D=$K/Apps/$N; A="/Applications/$N.app"; LOG="$HOME/Library/Logs/ARRA Oracles/$N.log"
fail=0
ok()  { print -r -- "✓ $1"; }
bad() { print -r -- "✗ $1"; shift; for l in "$@"; do print -r -- "    $l"; done; fail=1; }
[ -d $D ] || { print -r -- "✗ no Apps/$N in $K — generate it:  zsh $K/scripts/new-oracle-app.sh $N <org/repo> <checkout> '<#hex>' <symbol> \"<tagline>\""; exit 2; }

KEY=$(sed -n 's/^ *PRODUCT_BUNDLE_IDENTIFIER: co\.laris\.oracle\.\([a-z0-9-]*\)$/\1/p' $D/app.yml | head -1)
PORT=$(rg -o --no-filename 'port: [0-9]+' $D/${N}App.swift | sed 's/port: //' | head -1)
SLUG=$(sed -n 's/.*repoSlug: "\([^"]*\)".*/\1/p' $D/${N}Config.swift | head -1)
RULE=${SLUG#*/}; RULE=${RULE%-[Oo]racle}; RULE=${(L)RULE}

# portal key — the hub matches an app to its oracle by this
[[ $KEY == $RULE ]] && ok "portal key   co.laris.oracle.$KEY ($SLUG)" \
  || bad "portal key   co.laris.oracle.$KEY, but the portal looks for $RULE ($SLUG)" "zsh $K/scripts/new-oracle-app.sh $N … --update --key $RULE"

# the engines the generator must have written
for want in 'BundledANE.installLazily()' 'MapLayoutEngine.install()' "MCPServer.serve(name:"; do
  rg -qF "$want" $D/${N}App.swift && ok "app wires    $want" || bad "app lacks    $want" "regenerate:  zsh $K/scripts/new-oracle-app.sh $N … --update"
done

# installed copy
if [ -d "$A" ]; then
  ID=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$A/Contents/Info.plist" 2>/dev/null)
  V=$(/usr/libexec/PlistBuddy -c 'Print :ARRACalVer' "$A/Contents/Info.plist" 2>/dev/null)
  [[ $ID == co.laris.oracle.$KEY ]] && ok "installed    $A" || bad "installed    $A is $ID, expected co.laris.oracle.$KEY" "zsh $K/scripts/build.sh $N --install"
  [[ $V == *$(date +%y.%-m.%-d)* ]] && ok "CalVer       $V" || bad "CalVer       ${V:-none} — not built today" "zsh $K/scripts/build.sh $N --install"
else
  bad "not installed: $A" "zsh $K/scripts/build.sh $N --install"
fi

# launches — by full path (LaunchServices knows many copies: every worktree build registers one)
mkdir -p $K/build; MARK=$K/build/.check-$N; : > $MARK
if (( LAUNCH )) && [ -d "$A" ]; then
  pkill -x "$N"; for i in {1..50}; do pgrep -x "$N" >/dev/null || break; sleep 0.2; done
  open "$A" --args -oracleSection status
  sleep 10
fi
RUN=$(pgrep -fl "$N.app/Contents/MacOS/$N" | head -1)
if [[ $RUN == *" /Applications/$N.app/"* ]]; then ok "running      ${RUN%% *} from /Applications"
elif [[ -n $RUN ]]; then bad "running from elsewhere: ${RUN#* }" "osascript -e 'quit app \"$N\"'; open \"$A\""
else bad "not running" "open \"$A\"; tail -20 \"$LOG\""; fi
CR=(${(f)"$(find $HOME/Library/Logs/DiagnosticReports -maxdepth 1 -name "$N-*" -newer $MARK 2>/dev/null)"})
(( ${#CR[@]} == 0 )) || [[ -z ${CR[1]:-} ]] && ok "no crash     since launch" || bad "crashed      ${CR[1]}" "head -60 '${CR[1]}'"

# MCP memory server
H=$(curl -s -m 3 127.0.0.1:$PORT/health)
[[ $H == *'"status":"ok"'* ]] && ok "MCP :$PORT    ${H[1,90]}" \
  || bad "MCP :$PORT not answering" "lsof -nP -iTCP:$PORT -sTCP:LISTEN    # who holds the port" "tail -20 \"$LOG\""

# widget — registered once the app has launched from its final path
W=$(pluginkit -m -i co.laris.oracle.$KEY.widget 2>/dev/null)
[[ -z $W ]] && { sleep 5; W=$(pluginkit -m -i co.laris.oracle.$KEY.widget 2>/dev/null); }
[[ -n $W ]] && ok "widget       ${W//[[:space:]]/}" || bad "widget co.laris.oracle.$KEY.widget not registered" "open \"$A\"; sleep 5; pluginkit -m -i co.laris.oracle.$KEY.widget"

# the generator still produces what every app is
P=$(zsh $K/scripts/parity.sh 2>&1); [[ $? == 0 ]] && ok "parity       $(print -r -- $P | rg -c '^✓') apps match the generator" || bad "parity" ${(f)P}

if (( DEEP )); then
  # Memory then Map, each driven by a launch argument; pass only on the line the app writes when the work is DONE,
  # read from the lines written after this launch (the log is appended across runs).
  deep() {   # deep <section> <action> <done-regex> <timeout-s> [extra args…]
    local sec=$1 act=$2 re=$3 limit=$4; shift 4
    pkill -x "$N"; for i in {1..50}; do pgrep -x "$N" >/dev/null || break; sleep 0.2; done
    local n0=$(wc -l < "$LOG" 2>/dev/null || echo 0)
    open "$A" --args -oracleSection $sec -memoryAction $act "$@"
    local t=0 hit=""
    while (( t < limit )); do
      sleep 5; t=$((t + 5))
      hit=$(tail -n +$((n0 + 1)) "$LOG" 2>/dev/null | rg -m1 "$re")
      [[ -n $hit ]] && break
    done
    print -r -- "$hit"
  }
  Q=${(L)N}
  B=$(deep memory batch 'memory batch done' 600 -memoryQuery "$Q")
  [[ -n $B ]] && ok "Memory       ${B#* info   }" || bad "Memory       no 'memory batch done' within 10 min" "tail -30 \"$LOG\""
  S=""; for i in {1..6}; do S=$(tail -n 400 "$LOG" | rg "search \"$Q\"" | tail -1); [[ -n $S ]] && break; sleep 5; done
  [[ -n $S ]] && ok "Memory query ${S#* search }" || bad "Memory query \"$Q\" not searched" "rg -n 'search' \"$LOG\" | tail -5"
  M=$(deep map layout 'map layout: [0-9]+ docs in' 300)
  [[ -n $M ]] && ok "Map          ${M#* info   }" || bad "Map          no layout within 5 min" "rg -n 'map layout' \"$LOG\" | tail -5"
fi

if (( SHOTS )); then
  mkdir -p $K/build/shots
  for s in status memory map; do WAIT=10 zsh $K/scripts/shot.sh $N $K/build/shots/$N-$s.png -- -oracleSection $s | rg '^(shot|✗)'; done
fi

if (( IOS )); then
  xcodebuild -project $K/OracleApps.xcodeproj -scheme $N -destination 'generic/platform=iOS' -derivedDataPath $K/build/ios \
    CODE_SIGNING_ALLOWED=NO build >$K/build/ios-$N.log 2>&1 \
    && ok "iOS compiles" || bad "iOS build failed" "rg 'error:' $K/build/ios-$N.log | sort -u | head"
fi

rm -f $MARK
(( fail )) && { print -r -- "— $N: not all green"; exit 1; } || print -r -- "— $N: all green"
