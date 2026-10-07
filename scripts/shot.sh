#!/usr/bin/env zsh
# shot.sh <App> [out.png] [-- launch args…]   e.g.  shot.sh Pulse pulse-map.png -- -oracleSection map
# Relaunch /Applications/<App>.app (full path: LaunchServices knows many copies from worktree builds) with
# launch arguments, wait WAIT seconds (default 12), screenshot its largest window by window id (never a screen
# region, never a click), and tail the app's log. Needs Screen Recording for this terminal, once.
set -u
APP=${1:?App}; shift; OUT=$APP.png
[[ ${1:-} != "" && ${1:-} != -- ]] && { OUT=$1; shift; }
[[ ${1:-} == -- ]] && shift
pkill -x "$APP"; for i in {1..50}; do pgrep -x "$APP" >/dev/null || break; sleep 0.2; done
open "/Applications/$APP.app" --args "$@" || { sleep 2; open "/Applications/$APP.app" --args "$@"; }
sleep ${WAIT:-12}
pgrep -fl "$APP.app/Contents/MacOS" | rg -q "^.* /Applications/" || echo "! $APP is not running from /Applications:  pgrep -fl '$APP.app/Contents/MacOS'"
W=$(swift -e 'import CoreGraphics
let l = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as! [[String: Any]]
var best = 0, id = 0
for w in l where (w[kCGWindowOwnerName as String] as? String) == "'"$APP"'" && (w[kCGWindowLayer as String] as? Int) == 0 {
  let b = w[kCGWindowBounds as String] as! [String: Any]; let a = (b["Width"] as! Int) * (b["Height"] as! Int)
  if a > best { best = a; id = w[kCGWindowNumber as String] as! Int } }
print(id)' 2>/dev/null)
if [[ -n $W && $W != 0 ]]; then screencapture -x -o -l$W "$OUT" && echo "shot $OUT"
else echo "✗ no window for $APP — Screen Recording for this terminal?  System Settings → Privacy & Security → Screen Recording"; fi
L="$HOME/Library/Logs/ARRA Oracles/$APP.log"; [ -f "$L" ] && tail -5 "$L"
