#!/usr/bin/env zsh
# check.sh <Name> [--relaunch] [--no-launch] [--shots] [--deep] [--ios]
# The acceptance rows of /oracle-app for an app built from this kit and installed in /Applications.
# Prints ✓/✗ per row; every ✗ carries the command that fixes or narrows it. Exit 0 = all green, 1 = a ✗, 2 = usage.
#
# A human may be using the app. By default this NEVER kills it: a running copy is checked as it is, a stopped one is
# launched. --shots and --deep must relaunch it (they drive pages by launch argument), so they need --relaunch when the
# app is already running. --no-launch never launches or kills anything. Relaunching waits for no install: if another
# agent holds the install lock (scripts/install-lock.sh), the relaunching rows are skipped as ✗.
#   --relaunch   allowed to quit and relaunch a running copy
#   --no-launch  read-only: never launch, never quit
#   --shots      window screenshots of status / memory / map into build/shots/   (needs Screen Recording)
#   --deep       Memory batch + query, Map layout, by launch argument; reads the app's log   (loads the model; minutes)
#   --ios        compile the iOS target (no device, no signing)
set -u
ARGV_ALL=("$@")
N=${1:-}; [[ -n $N && $N != --* ]] || { print -r -- "usage: check.sh <Name> [--relaunch] [--no-launch] [--shots] [--deep] [--ios]"; exit 2; }; shift
RELAUNCH=0 NOLAUNCH=0 SHOTS=0 DEEP=0 IOS=0
for a in "$@"; do case $a in
  --relaunch) RELAUNCH=1;; --no-launch) NOLAUNCH=1;; --shots) SHOTS=1;; --deep) DEEP=1;; --ios) IOS=1;;
  *) print -r -- "✗ unknown option $a — usage: check.sh <Name> [--relaunch] [--no-launch] [--shots] [--deep] [--ios]"; exit 2;;
esac; done
K=${0:A:h}/../..; K=${K:A}; D=$K/Apps/$N; A="/Applications/$N.app"; LOG="$HOME/Library/Logs/ARRA Oracles/$N.log"
source $K/scripts/install-lock.sh
fail=0
ok()  { print -r -- "✓ $1"; }
bad() { print -r -- "✗ $1"; shift; for l in "$@"; do print -r -- "    $l"; done; fail=1; }
[ -d $D ] || { print -r -- "✗ no Apps/$N in $K — generate it:  zsh $K/scripts/new-oracle-app.sh $N <org/repo> <checkout> '<#hex>' <sf.symbol> \"<tagline>\""; exit 2; }

C=$D/${N}Config.swift
get() { sed -n "s/.*$1: \"\\([^\"]*\\)\".*/\\1/p" $C | head -1; }
SLUG=$(get repoSlug); HEX=$(get colorHex); SYM=$(get symbol); TAG=$(get tagline)
LP=$(sed -n 's/.*OracleConfig.mac("\([^"]*\)").*/\1/p' $C | head -1)
KEY=$(sed -n 's/^ *PRODUCT_BUNDLE_IDENTIFIER: co\.laris\.oracle\.\([a-z0-9-]*\)$/\1/p' $D/app.yml | head -1)
PORT=$(sed -n 's/.*port: \([0-9][0-9]*\).*/\1/p' $D/${N}App.swift | head -1)
RULE=${(L)${SLUG#*/}}; RULE=${RULE%-oracle}; RULE=${RULE//[_.]/-}   # = HubParse.appKey(forRepo:) (case-insensitive -oracle)
REGEN="zsh $K/scripts/new-oracle-app.sh ${(q)N} ${(q)SLUG} ${(q)LP} ${(q)HEX} ${(q)SYM} ${(q)TAG} --update"

# portal key — the hub matches an app to its oracle by this
[[ $KEY == $RULE ]] && ok "portal key   co.laris.oracle.$KEY ($SLUG)" || bad "portal key   co.laris.oracle.$KEY, but the portal looks for $RULE ($SLUG)" "$REGEN --key=$RULE"

# the engines the generator must have written
for want in 'BundledANE.installLazily()' 'MapLayoutEngine.install()' "MCPServer.serve(name: \"${(L)N}-memory\", port: $PORT)"; do
  rg -qF "$want" $D/${N}App.swift && ok "app wires    $want" || bad "app lacks    $want" "$REGEN"
done

# installed copy: identity + CalVer (stamped in Bangkok time by scripts/calver-stamp.sh)
if [ -d "$A" ]; then
  P=$A/Contents/Info.plist
  ID=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$P" 2>/dev/null)
  DN=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleDisplayName' "$P" 2>/dev/null)
  V=$(/usr/libexec/PlistBuddy -c 'Print :ARRACalVer' "$P" 2>/dev/null)
  [[ $ID == co.laris.oracle.$KEY && $DN == $N ]] && ok "installed    $A ($ID, \"$DN\")" || bad "installed    $A is $ID \"$DN\", expected co.laris.oracle.$KEY \"$N\"" "zsh $K/scripts/build.sh $N --install"
  [[ $V == *$(TZ=Asia/Bangkok date +%y.%-m.%-d)* ]] && ok "CalVer       $V" || bad "CalVer       ${V:-none} — not built today (Bangkok)" "zsh $K/scripts/build.sh $N --install"
else
  bad "not installed: $A" "zsh $K/scripts/build.sh $N --install"
fi

running() { pgrep -fl "$N\.app/Contents/MacOS/$N( |\$)" | head -1 }   # launch arguments may follow the binary
quit_app() { pkill -x "$N"; for i in {1..50}; do pgrep -x "$N" >/dev/null || return 0; sleep 0.2; done }
launch() { for i in 1 2 3; do open "$A" --args "$@" 2>/dev/null && return 0; sleep 2; done; return 1 }   # -600 while quitting
# may this run relaunch the app? (it is ours to quit only with --relaunch, and never during another agent's install)
may_relaunch() {
  (( NOLAUNCH )) && { print -r -- "--no-launch"; return 1; }
  lock_held && { print -r -- "install in progress by $(cat $LOCK_DIR/who 2>/dev/null)"; return 1; }
  [[ -n $(running) ]] && (( ! RELAUNCH && ! OURS )) && { print -r -- "$N is running (a human may be using it) — add --relaunch"; return 1; }
  return 0
}

# launches — by full path (LaunchServices knows many copies: every worktree build registers one)
mkdir -p $K/build; MARK=$K/build/.check-$N; : > $MARK; OURS=0
if [[ -z $(running) ]] && (( ! NOLAUNCH )) && [ -d "$A" ]; then
  if lock_held; then bad "not launched — install in progress by $(cat $LOCK_DIR/who 2>/dev/null)" "while kill -0 $(cat $LOCK_DIR/pid 2>/dev/null) 2>/dev/null; do sleep 5; done; zsh $0 ${(j: :)${(@q)ARGV_ALL}}"
  else launch -oracleSection status; OURS=1; sleep 10; fi    # the copy this run started is not a human's
fi
RUN=$(running)
# crashes count from this copy's start (a copy already running was started before this run)
if [[ -n $RUN ]] && (( ! OURS )); then
  st=$(ps -o lstart= -p ${RUN%% *} 2>/dev/null); [[ -n $st ]] && touch -t $(date -j -f "%a %b %d %T %Y" "$st" +%Y%m%d%H%M.%S 2>/dev/null) $MARK 2>/dev/null
fi
if [[ $RUN == *" /Applications/$N.app/"* ]]; then ok "running      ${RUN%% *} from /Applications"
elif [[ -n $RUN ]]; then bad "running from elsewhere: ${RUN#* }" "pgrep -fl '$N.app/Contents/MacOS'   # whose copy? ask before quitting it, then: open \"$A\""
else bad "not running" "open \"$A\"; tail -20 \"$LOG\""; fi
CR=()
for c in $HOME/Library/Logs/DiagnosticReports/{$N,${N}Widget,${N}Share}-*(N); do [[ $c -nt $MARK ]] && CR+=($c); done
(( $#CR )) && bad "crashed      ${CR[1]}" "head -60 '${CR[1]}'" || ok "no crash     app, widget or share since launch"

# MCP memory server — this app's own (another app answering on the port is a ✗)
H=$(curl -s -m 3 127.0.0.1:$PORT/health)
if [[ $H == *'"status":"ok"'* && $H == *"\"name\":\"${(L)N}-memory\""* ]]; then ok "MCP :$PORT    ${(L)N}-memory ok"
elif [[ -n $H ]]; then bad "MCP :$PORT answers as another server: ${H[1,120]}" "lsof -nP -iTCP:$PORT -sTCP:LISTEN"
else bad "MCP :$PORT not answering" "lsof -nP -iTCP:$PORT -sTCP:LISTEN" "tail -20 \"$LOG\""; fi
# MCP memory_search answers, and Trace records the query with its caller (<Name>-queries.jsonl)
TQ="$HOME/Library/Logs/ARRA Oracles/$N-queries.jsonl"; q0=0; [ -f "$TQ" ] && q0=$(wc -l < "$TQ"); MQ="check ${(L)N} $$"
MR=$(curl -s -m 30 -X POST 127.0.0.1:$PORT/mcp -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' \
  -d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"memory_search\",\"arguments\":{\"query\":\"$MQ\"}}}")
TR=$(tail -n +$((q0 + 1)) "$TQ" 2>/dev/null | rg -F "\"query\":\"$MQ\"" | rg -F '"source":"mcp"' | rg -F '"caller":"' | tail -1)   # this exact query, via MCP, with a caller
if [[ $MR == *'"result"'* && $MR != *'"isError":true'* ]]; then ok "MCP search   memory_search answered"; else bad "MCP search   memory_search failed: ${MR[1,160]}" "tail -20 \"$LOG\""; fi
[[ -n $TR ]] && ok "Trace        query recorded, caller $(print -r -- $TR | sed -n 's/.*"caller":"\([^"]*\)".*/\1/p' | sed 's#\\/#/#g')" || bad "Trace        no query recorded in $TQ" "tail -3 \"$TQ\""

# widget — registered from the /Applications copy (a worktree build registers its own)
wpath() { pluginkit -m -v -i co.laris.oracle.$KEY.widget 2>/dev/null | rg -o '/[^\t]*\.appex' | head -1 }
WP=$(wpath); [[ $WP == /Applications/$N.app/* ]] || { sleep 5; WP=$(wpath); }
if [[ $WP == /Applications/$N.app/* ]]; then ok "widget       co.laris.oracle.$KEY.widget from /Applications"
elif [[ -n $WP ]]; then bad "widget registered from $WP, not /Applications" "pluginkit -r '$WP'; open \"$A\""
else bad "widget co.laris.oracle.$KEY.widget not registered" "open \"$A\"; sleep 5; pluginkit -m -v -i co.laris.oracle.$KEY.widget"; fi

# the generator still produces what every app is
PO=$(zsh $K/scripts/parity.sh 2>&1); [[ $? == 0 ]] && ok "parity       $(print -r -- $PO | rg -c '^✓') apps match the generator" || bad "parity" ${(f)PO}

if (( DEEP )); then
  # Memory then Map, each driven by a launch argument. Pass only on the line the app writes when the work is DONE, read
  # from the lines written after that launch (the log is appended across runs):
  #   batch → "memory batch done — …", or with nothing new "up to date — nothing new …"; ends early on a fatal engine
  #   error ("no embedder", "another vector space"); other error lines (gh gave nothing) are not fatal.
  #   map   → "map layout: N docs in X s" (fitted now) or "map: N points in K chunks" (a cached layout, drawn)
  FATAL='^[0-9:.]+ error  .*(no embedder|another vector space)'
  N0=0
  deep() {   # deep <section> <action> <done-regex> <timeout-s> [extra args…]   (sets N0: the log's length at launch)
    local sec=$1 act=$2 re=$3 limit=$4; shift 4
    lock_held && { print -r -- "LOCKED"; return; }   # another agent began installing since the check started
    quit_app
    local n0=0; [ -f "$LOG" ] && n0=$(wc -l < "$LOG"); N0=$n0
    launch -oracleSection $sec -memoryAction $act "$@" || { print -r -- ""; return; }
    local t=0 hit=""
    while (( t < limit )); do
      sleep 5; t=$((t + 5))
      hit=$(tail -n +$((n0 + 1)) "$LOG" 2>/dev/null | rg -m1 -e "$re" -e "$FATAL")
      [[ -n $hit ]] && break
    done
    print -r -- "$hit"
  }
  if why=$(may_relaunch); then
    Q=${(L)N}
    deep memory batch '^[0-9:.]+ info   (memory batch done|up to date — nothing new in )' 600 -memoryQuery "$Q" > $MARK.out; B=$(<$MARK.out)
    if [[ $B == LOCKED ]]; then bad "Memory       not run: install in progress by $(cat $LOCK_DIR/who 2>/dev/null)" "zsh $0 $N --deep --relaunch"
    elif [[ $B == *" error  "* ]]; then bad "Memory       ${B#* error  }" "open \"$A\" --args -oracleSection memory    # the engine card says what is missing"
    elif [[ -n $B ]]; then ok "Memory       ${B#* info   }"
    else bad "Memory       no batch result within 10 min" "tail -30 \"$LOG\""; fi
    S=""; if [[ $B != LOCKED ]]; then   # a batch that never ran has no query to read (N0 would still be 0)
      for i in {1..6}; do S=$(tail -n +$((N0 + 1)) "$LOG" | rg "search [a-z]+ .*\"$Q\" · query embedded" | tail -1); [[ -n $S ]] && break; sleep 5; done
    fi
    hits=$(print -r -- "$S" | sed -n 's/.*ranked \([0-9,]*\) in.*/\1/p' | tr -d ,); best=$(print -r -- "$S" | sed -n 's/.*best \([0-9]*\)%.*/\1/p')
    if [[ $B == LOCKED ]]; then :
    elif [[ -n $S ]] && (( ${hits:-0} > 0 && ${best:-0} > 0 )); then ok "Memory query ${S#* search }"
    elif [[ -n $S ]]; then bad "Memory query \"$Q\" found nothing (ranked ${hits:-0}, best ${best:-0}%)" "open \"$A\" --args -oracleSection memory   # is the index empty?"
    else bad "Memory query \"$Q\" not searched" "rg -n 'search' \"$LOG\" | tail -5"; fi
    M=$(deep map layout 'map layout: [0-9]+ docs in|map: [0-9]+ points in' 300)
    mn=$(print -r -- "$M" | sed -En 's/.*map( layout)?: ([0-9]+) (docs|points).*/\2/p')   # -E: BSD sed has no \| in basic regex
    if [[ $M == LOCKED ]]; then bad "Map          not run: install in progress by $(cat $LOCK_DIR/who 2>/dev/null)" "zsh $0 $N --deep --relaunch"
    elif [[ -n $M ]] && (( ${mn:-0} > 0 )); then ok "Map          ${M#* info   }"
    elif [[ -n $M ]]; then bad "Map          drew no points: ${M#* info   }" "open \"$A\" --args -oracleSection memory   # embed first (--deep runs the batch)"
    else bad "Map          no layout drawn within 5 min" "rg -n 'map' \"$LOG\" | tail -5"; fi
  else bad "Memory / Map not run: $why" "zsh $0 $N --deep --relaunch"; fi
fi

if (( SHOTS )); then
  if why=$(may_relaunch); then
    mkdir -p $K/build/shots
    for s in status memory map; do
      out=$(WAIT=10 zsh $K/scripts/shot.sh $N $K/build/shots/$N-$s.png -- -oracleSection $s 2>&1); src=$?
      (( src == 0 )) && [[ ${out%%$'\n'*} == "shot "* ]] && ok "screenshot   build/shots/$N-$s.png" || bad "screenshot   $s failed (rc $src)" ${(f)out}
    done
  else bad "screenshots not taken: $why" "zsh $0 $N --shots --relaunch"; fi
fi

if (( IOS )); then
  xcodebuild -project $K/OracleApps.xcodeproj -scheme $N -destination 'generic/platform=iOS' -derivedDataPath $K/build/ios \
    CODE_SIGNING_ALLOWED=NO build >$K/build/ios-$N.log 2>&1 \
    && ok "iOS compiles" || bad "iOS build failed" "rg 'error:' $K/build/ios-$N.log | sort -u | head"
fi

rm -f $MARK $MARK.out
(( fail )) && { print -r -- "— $N: not all green"; exit 1; } || { print -r -- "— $N: all green"; exit 0; }
