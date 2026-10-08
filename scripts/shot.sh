#!/usr/bin/env zsh
# shot.sh <App> [out.png] [-- launch args…]     relaunch <App> with launch arguments, then screenshot its window
# shot.sh <App> [out.png] --as-is                screenshot the window as it is: no quit, no relaunch (the hub a human
#                                                is using; any app you must not disturb)
# Relaunches /Applications/<App>.app by full path (LaunchServices knows many copies from worktree builds), waits WAIT
# seconds (default 12), screenshots its largest window by window id — never a screen region, never a click — and tails
# the app's log. Refuses to relaunch while another agent holds the install lock. Needs Screen Recording, once.
# Exit 0 = shot taken · 1 = no window / capture failed · 3 = the screen is locked · 75 = another agent is installing.
set -u
R=${0:A:h}/..; R=${R:A}; source $R/scripts/install-lock.sh
ARGV_ALL=("$@")
APP=${1:?usage: shot.sh <App> [out.png] [-- launch args… | --as-is]}; shift
OUT=$APP.png; ASIS=0
[[ ${1:-} != "" && ${1:-} != -- && ${1:-} != --as-is ]] && { OUT=$1; shift; }
[[ ${1:-} == --as-is ]] && { ASIS=1; shift; }
[[ ${1:-} == -- ]] && shift
# `shot.sh Maeon` still works after #90 renamed the bundle to "Maeon Oracle.app"
[[ -d "/Applications/$APP.app" || ! -d "/Applications/$APP Oracle.app" ]] || APP="$APP Oracle"
# a locked screen cannot be captured (screencapture: "could not create image from window") — say so, not "permission"
LOCKED=$(swift -e 'import CoreGraphics; let d = CGSessionCopyCurrentDictionary() as? [String: Any] ?? [:]; print((d["CGSSessionScreenIsLocked"] as? Int) ?? 0)' 2>/dev/null)
[[ $LOCKED == 1 ]] && { print -r -- "✗ the screen is locked — a window cannot be captured; unlock it, then:  zsh $0 ${(@q)ARGV_ALL}"; exit 3; }
if (( ! ASIS )); then
  if lock_held; then
    print -r -- "✗ not relaunching $APP: install in progress by $(cat $LOCK_DIR/who 2>/dev/null) — wait for it, or capture as it is:"
    print -r -- "    while kill -0 $(cat $LOCK_DIR/pid 2>/dev/null) 2>/dev/null; do sleep 5; done; zsh $0 ${(@q)ARGV_ALL}"
    print -r -- "    zsh $0 ${(q)APP} ${(q)OUT} --as-is"; exit 75
  fi
  pkill -x "$APP"; for i in {1..50}; do pgrep -x "$APP" >/dev/null || break; sleep 0.2; done
  # without this pane's HERDR_*, as build.sh relaunches: `open` hands the caller's environment to the app (#97)
  for i in 1 2 3; do ( unset -m 'HERDR_*' 'CLAUDE_CODE_*' CLAUDECODE; open "/Applications/$APP.app" --args "$@" ) 2>/dev/null && break; sleep 2; done   # -600 while quitting
  sleep ${WAIT:-12}
fi
pgrep -fl "$APP.app/Contents/MacOS" | rg -q " /Applications/" || print -r -- "! $APP is not running from /Applications:  pgrep -fl '$APP.app/Contents/MacOS'"
# the window by its process id, not its owner name: macOS reports the DISPLAY name there ("Maeon Oracle" for the Maeon
# executable, #77), and display names change; the executable path does not
PIDS=$(pgrep -f "/Applications/$APP.app/Contents/MacOS/$APP( |\$)" | tr '\n' ',')
[[ -z $PIDS ]] && PIDS=$(pgrep -f "/$APP.app/Contents/MacOS/$APP( |\$)" | tr '\n' ',')   # running from a worktree build
W=$(swift -e 'import CoreGraphics
let pids = Set("'"$PIDS"'".split(separator: ",").compactMap { Int($0) })
let l = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as! [[String: Any]]
var best = 0, id = 0
for w in l where pids.contains((w[kCGWindowOwnerPID as String] as? Int) ?? -1) && (w[kCGWindowLayer as String] as? Int) == 0 {
  let b = w[kCGWindowBounds as String] as! [String: Any]; let a = (b["Width"] as! Int) * (b["Height"] as! Int)
  if a > best { best = a; id = w[kCGWindowNumber as String] as! Int } }
print(id)' 2>/dev/null)
rc=0
mkdir -p "${OUT:h}" 2>/dev/null
if [[ -n $W && $W != 0 ]] && screencapture -x -o -l$W "$OUT"; then print -r -- "shot $OUT"
elif [[ $(swift -e 'import CoreGraphics; let d = CGSessionCopyCurrentDictionary() as? [String: Any] ?? [:]; print((d["CGSSessionScreenIsLocked"] as? Int) ?? 0)' 2>/dev/null) == 1 ]]; then
  print -r -- "✗ the screen locked during the wait — unlock it, then:  zsh $0 ${(@q)ARGV_ALL}"; rc=3
else
  print -r -- "✗ no window for $APP — not running, off screen, or no Screen Recording for this terminal:"
  print -r -- "    pgrep -fl '$APP.app/Contents/MacOS'; ls -t ~/Library/Logs/DiagnosticReports | rg -m1 '^${APP}(Widget|Share)?-'"
  print -r -- "    swift -e 'import CoreGraphics; print(CGPreflightScreenCaptureAccess())'   # false → open 'x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture'"
  rc=1
fi
L="$HOME/Library/Logs/ARRA Oracles/${APP% Oracle}.log"; [[ $APP == "ARRA Oracles" ]] && L="$HOME/Library/Logs/ARRA Oracles/embed.log"   # the hub logs to embed.log
[ -f "$L" ] && tail -5 "$L"
exit $rc
