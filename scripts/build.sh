#!/usr/bin/env zsh
# build.sh [Scheme …] [--install]   (default schemes: Oracles Neo Pulse Nexus)
# Release build of each scheme from THIS checkout (its own build/ — two worktrees never share derived data),
# errors and the result per scheme. --install also copies each built app into /Applications under the install
# lock and relaunches the ones that were running (the hub always). Run it in a herdr pane: it takes minutes.
# ORACLE_APP_TEAM=<id> signs with that team instead of project.yml's (another Apple account on this Mac).
set -u
R=${0:A:h}/..; R=${R:A}; cd $R || exit 2
source $R/scripts/install-lock.sh
INSTALL=0; schemes=()
for a in "$@"; do [[ $a == --install ]] && INSTALL=1 || schemes+=($a); done
(( $#schemes )) || schemes=(Oracles Neo Pulse Nexus)
mkdir -p build/logs
zsh scripts/regen.sh >/dev/null || { echo "✗ regen failed:  zsh $R/scripts/regen.sh"; exit 3; }
rc=0; built=()
for s in $schemes; do
  log=build/logs/$s.log
  xcodebuild -project OracleApps.xcodeproj -scheme $s -configuration Release -destination 'platform=macOS' -derivedDataPath build ${ORACLE_APP_TEAM:+DEVELOPMENT_TEAM=$ORACLE_APP_TEAM} build >$log 2>&1
  r=$?; (( r )) && rc=$r || built+=($s)
  echo "== $s rc=$r $(rg -o 'BUILD (SUCCEEDED|FAILED)' $log | tail -1)"
  (( r )) && { rg 'error:' $log | sed "s|^$R/||" | sort -u | head -12; echo "  full log: $R/$log"; }
done
(( INSTALL && $#built )) || exit $rc
lock_take "zsh $R/scripts/build.sh ${(q)@}" || exit 75
trap lock_drop EXIT; trap 'lock_drop; exit 130' INT TERM HUP
for s in $built; do
  app=$s; [[ $s == Oracles ]] && app="ARRA Oracles"
  was=0; pgrep -x "$app" >/dev/null && was=1; [[ $app == "ARRA Oracles" ]] && was=1
  pkill -x "$app"; for i in {1..50}; do pgrep -x "$app" >/dev/null || break; sleep 0.2; done
  if ! rsync -a --delete "$R/build/Build/Products/Release/$app.app/" "/Applications/$app.app/"; then
    print -r -- "✗ $app: copying into /Applications failed — nothing relaunched:  ls -ld '/Applications/$app.app'"; rc=1; continue
  fi
  v=$(/usr/libexec/PlistBuddy -c "Print :ARRACalVer" "/Applications/$app.app/Contents/Info.plist" 2>/dev/null)
  if (( was )); then for i in 1 2 3; do open "/Applications/$app.app" 2>/dev/null && break; sleep 2; done; fi   # -600 while the old copy quits
  echo "$app $v $( (( was )) && echo relaunched || echo installed)"
done
exit $rc
