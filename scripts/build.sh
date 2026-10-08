#!/usr/bin/env zsh
# build.sh [Scheme …] [--install]   (default schemes: Oracles Neo Pulse Nexus)
# Release build of each scheme from THIS checkout (its own build/ — two worktrees never share derived data),
# errors and the result per scheme. --install also copies each built app into /Applications under the install
# lock and relaunches the ones that were running (the hub always). Run it in a herdr pane: it takes minutes.
# ORACLE_APP_TEAM=<id> signs with that team instead of project.yml's (another Apple account on this Mac).
set -u
R=${0:A:h}/..; R=${R:A}; cd $R || exit 2
source $R/scripts/install-lock.sh
source $R/scripts/team.sh
INSTALL=0; schemes=()
for a in "$@"; do [[ $a == --install ]] && INSTALL=1 || schemes+=($a); done
if (( ! $#schemes )); then
  if (( INSTALL )); then
    have=(${(f)"$(for a in Apps/*/app.yml(N); do print ${a:h:t}; done | rg -v -x 'Hub|MapSpike|Shared')"})
    print -r -- "✗ name the apps to install — --install with no names would replace the hub and every app. Apps here: ${have[*]} Oracles (the hub)"
    print -r -- "    zsh $0 ${have[1]:-Neo} --install"; exit 2
  fi
  schemes=(Oracles Neo Pulse Nexus)
fi
# the signing team: $ORACLE_APP_TEAM, else project.yml's if a certificate here has it, else this Mac's only certificate's
if [ -z "${ORACLE_APP_TEAM:-}" ]; then
  pteam=$(project_team); teams=(${(f)"$(cert_teams)"})
  if (( ! ${teams[(Ie)$pteam]} )); then
    if (( $#teams == 1 )); then export ORACLE_APP_TEAM=$teams[1]; print -r -- "! signing with this Mac's only team $ORACLE_APP_TEAM (project.yml has $pteam)"
    elif (( $#teams == 0 )); then print -r -- "✗ no signing certificate on this Mac — Xcode → Settings → Accounts → sign in, then:  zsh $0 ${(j: :)${(q)@}}"; exit 2
    else print -r -- "✗ several signing teams here (${teams[*]}), none is project.yml's $pteam — pick one:"; for t in $teams; do print -r -- "    ORACLE_APP_TEAM=$t zsh $0 ${(j: :)${(q)@}}"; done; exit 2; fi
  fi
fi
mkdir -p build/logs
zsh scripts/regen.sh >/dev/null || { echo "✗ regen failed:  zsh $R/scripts/regen.sh"; exit 3; }
# this run's CalVer, fixed once: every target (app, widget, share) gets it as its version BUILD SETTING, so the
# processed Info.plists differ from the last build's and Xcode re-signs and re-embeds the extensions (a stamp edited in
# afterwards does not make an incremental build re-copy them). calver-stamp.sh adds ARRACalVer from the same value.
CV_V=$(TZ=Asia/Bangkok date +%y.%-m.%-d); CV_H=$(( 10#$(TZ=Asia/Bangkok date +%H) * 100 + 10#$(TZ=Asia/Bangkok date +%M) ))
export ORACLE_CALVER="$CV_V $CV_H"
rc=0; built=()
for s in $schemes; do
  log=build/logs/$s.log
  xcodebuild -project OracleApps.xcodeproj -scheme $s -configuration Release -destination 'platform=macOS' -derivedDataPath build MARKETING_VERSION=$CV_V CURRENT_PROJECT_VERSION=$CV_H ${ORACLE_APP_TEAM:+DEVELOPMENT_TEAM=$ORACLE_APP_TEAM} build >$log 2>&1
  r=$?; (( r )) && rc=$r || built+=($s)
  echo "== $s rc=$r $(rg -o 'BUILD (SUCCEEDED|FAILED)' $log | tail -1)"
  (( r )) && { rg 'error:' $log | sed "s|^$R/||" | sort -u | head -12; echo "  full log: $R/$log"; }
done
(( INSTALL && $#built )) || exit $rc
lock_take "${ORACLE_APP_TEAM:+ORACLE_APP_TEAM=${(q)ORACLE_APP_TEAM} }zsh $R/scripts/build.sh ${(j: :)${(q)@}}" || exit 75
trap lock_drop EXIT; trap 'lock_drop; exit 130' INT TERM HUP
# the installed name is the main target's PRODUCT_NAME in Apps/<dir>/app.yml: "Maeon Oracle", "ARRA Oracles" (#90)
app_name() { local d=$1; [[ $d == Oracles ]] && d=Hub; rg -m1 -o --replace '$1' '^ {8}PRODUCT_NAME: (.+)$' "$R/Apps/$d/app.yml" 2>/dev/null || print -r -- "$1"; }
live() { pgrep -x "$1" >/dev/null || { [[ $2 != $1 ]] && pgrep -x "$2" >/dev/null } }   # the app, or its pre-#90 name
LSREG=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
for s in $built; do
  app=$(app_name $s)
  old="/Applications/$s.app"    # before #90 an oracle app's bundle was named after its scheme ("Maeon.app"), same bundle id
  was=0; live "$app" "$s" && was=1; [[ $app == "ARRA Oracles" ]] && was=1
  pkill -x "$app"; [[ $s != $app ]] && pkill -x "$s"; for i in {1..50}; do live "$app" "$s" || break; sleep 0.2; done
  if ! rsync -a --delete "$R/build/Build/Products/Release/$app.app/" "/Applications/$app.app/"; then
    print -r -- "✗ $app: copying into /Applications failed — nothing relaunched:  ls -ld '/Applications/$app.app'"; rc=1; continue
  fi
  # one copy per bundle id: LaunchServices — and the hub, which finds oracle apps by bundle id — would pick either
  if [[ $s != $app && -d $old ]]; then
    id_new=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "/Applications/$app.app/Contents/Info.plist" 2>/dev/null)
    id_old=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$old/Contents/Info.plist" 2>/dev/null)
    if [[ -n $id_new && $id_new == $id_old ]]; then
      $LSREG -u "$old" 2>/dev/null
      mv "$old" "$HOME/.Trash/$s $(date +%H%M%S).app" && print -r -- "  $old → Trash (now /Applications/$app.app, #90)"
    fi
  fi
  v=$(/usr/libexec/PlistBuddy -c "Print :ARRACalVer" "/Applications/$app.app/Contents/Info.plist" 2>/dev/null)
  if (( was )); then   # -600 while the old copy is still quitting: retry
    # without this pane's HERDR_*: `open` hands the caller's environment to the app, and an app holding a pane's
    # HERDR_SOCKET_PATH / HERDR_PANE_ID acts on that pane's herdr server (seen 2026-10-08)
    up=0; for i in 1 2 3; do ( unset -m 'HERDR_*' 'CLAUDE_CODE_*' CLAUDECODE; open "/Applications/$app.app" ) 2>/dev/null && { up=1; break; }; sleep 2; done
    (( up )) || { print -r -- "✗ $app $v: installed, but it did not start (open failed 3 times):  open '/Applications/$app.app'"; rc=1; continue; }
  fi
  echo "$app $v $( (( was )) && echo relaunched || echo installed)"
done
exit $rc
