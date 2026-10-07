#!/bin/sh
# Stamps the built app with its CalVer, Bangkok time at build: CFBundleShortVersionString yy.m.d, CFBundleVersion HMM
# (H*100+M, no leading zero), ARRACalVer vyy.m.d-alpha.HMM. The app shows it, so anyone can tell which build runs.
PLIST="$TARGET_BUILD_DIR/$INFOPLIST_PATH"
[ -f "$PLIST" ] || exit 0
V=$(TZ=Asia/Bangkok date +%y.%-m.%-d)
H=$(( 10#$(TZ=Asia/Bangkok date +%H) * 100 + 10#$(TZ=Asia/Bangkok date +%M) ))
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $V" "$PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $H" "$PLIST"
/usr/libexec/PlistBuddy -c "Delete :ARRACalVer" "$PLIST" 2>/dev/null
/usr/libexec/PlistBuddy -c "Add :ARRACalVer string v$V-alpha.$H" "$PLIST"
echo "calver v$V-alpha.$H"
