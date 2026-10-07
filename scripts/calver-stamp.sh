#!/bin/sh
# Stamps the built app with its CalVer, Bangkok time at build: CFBundleShortVersionString yy.m.d, CFBundleVersion HMM
# (H*100+M, no leading zero), ARRACalVer vyy.m.d-alpha.HMM. The app shows it, so anyone can tell which build runs.
# Its widget and share extension get the SAME stamp: Xcode warns when an extension's version differs from its app's,
# and App Store validation rejects it (ITMS-90473). `calver-stamp.sh begin` runs first in every build — the CalVer
# target in project.yml, which each app and extension depends on — and fixes this build's value in $OBJROOT.
F="$OBJROOT/oracle-calver"
now() {
  V=$(TZ=Asia/Bangkok date +%y.%-m.%-d)
  H=$(( 10#$(TZ=Asia/Bangkok date +%H) * 100 + 10#$(TZ=Asia/Bangkok date +%M) ))
}
mkdir -p "$OBJROOT"
if [ "${1:-}" = begin ]; then
  if [ -n "${ORACLE_CALVER:-}" ]; then echo "$ORACLE_CALVER" > "$F"; else now; echo "$V $H" > "$F"; fi   # build.sh fixes it once
  exit 0
fi
PLIST="$TARGET_BUILD_DIR/$INFOPLIST_PATH"
[ -f "$PLIST" ] || exit 0
V= H=; [ -f "$F" ] && read -r V H < "$F"
case "$V.$H" in *[!0-9.]*|.*|*.) now ;; esac      # no stamp for this build (a target built on its own): the time now
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $V" "$PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $H" "$PLIST"
/usr/libexec/PlistBuddy -c "Delete :ARRACalVer" "$PLIST" 2>/dev/null
/usr/libexec/PlistBuddy -c "Add :ARRACalVer string v$V-alpha.$H" "$PLIST"
echo "calver v$V-alpha.$H"
