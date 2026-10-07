#!/usr/bin/env zsh
# parity.sh [<Name> …]  — the generator must produce what the apps are.
# For each app (default: every Apps/* with a <Name>Config.swift — Hub, MapSpike, Shared have none), read its identity
# back from <Name>Config.swift / <Name>App.swift / app.yml / <Name>.entitlements, regenerate it into a scratch copy of
# the kit, and diff 7 generated files against the real ones. Exit 0 = no difference anywhere.
set -e
R=${0:A:h}/..; R=${R:A}
names=("$@")
if (( ! $#names )); then for d in $R/Apps/*(/); do [ -f $d/${d:t}Config.swift ] && names+=(${d:t}); done; fi
(( $#names )) || { print -r -- "✗ no app with a <Name>Config.swift under $R/Apps — nothing to compare:  ls $R/Apps"; exit 2; }
T=$(mktemp -d "${TMPDIR:-/tmp}/oracle-parity.XXXX")
trap 'rm -rf $T' EXIT; trap 'rm -rf $T; exit 130' INT TERM HUP
rsync -a --exclude build --exclude .build --exclude .git --exclude wt --exclude target --exclude .tmp $R/ $T/
rc=0
for N in $names; do
  C=$R/Apps/$N/${N}Config.swift; [ -f $C ] || { print -r -- "✗ $N: no Apps/$N/${N}Config.swift"; rc=1; continue; }
  get() { sed -n "s/.*$1: \"\\([^\"]*\\)\".*/\\1/p" $C | head -1; }
  SLUG=$(get repoSlug); HEX=$(get colorHex); SYM=$(get symbol); TAG=$(get tagline)
  LP=$(sed -n 's/.*OracleConfig.mac("\([^"]*\)").*/\1/p' $C | head -1)
  PORT=$(sed -n 's/.*port: \([0-9][0-9]*\).*/\1/p' $R/Apps/$N/${N}App.swift | head -1)
  KEY=$(sed -n 's/^ *PRODUCT_BUNDLE_IDENTIFIER: co\.laris\.oracle\.\([a-z0-9-]*\)$/\1/p' $R/Apps/$N/app.yml | head -1)
  TEAM=$(sed -n 's/.*<string>\([A-Z0-9]*\)\.co\.laris\.oracle\.[a-z0-9-]*<\/string>.*/\1/p' $R/Apps/$N/$N.entitlements | head -1)
  opts=(); [ -n "$KEY" ] && opts+=(--key=$KEY); [ -n "$PORT" ] && opts+=(--port=$PORT); [ -n "$TEAM" ] && opts+=(--team=$TEAM)
  rm -rf $T/Apps/$N
  if ! out=$(cd $T && ORACLE_APP_SCRATCH=1 zsh scripts/new-oracle-app.sh "$N" "$SLUG" "$LP" "$HEX" "$SYM" "$TAG" $opts --no-regen 2>&1); then
    # its hint was built for this scratch call: show it as the command to run in the real kit (--update, no --no-regen)
    print -r -- "✗ $N: the generator refused the identity read back from Apps/$N:"
    print -r -- "$out" | sed -e "s|zsh scripts/new-oracle-app.sh|zsh $R/scripts/new-oracle-app.sh --update|" -e 's| --no-regen||' -e 's/^/    /'; rc=1; continue
  fi
  bad=0
  for f in ${N}App.swift ${N}Config.swift app.yml Widget/${N}Widget.swift Share/ShareViewController.swift ${N}.entitlements Widget/${N}Widget.entitlements; do
    if ! diff -u $R/Apps/$N/$f $T/Apps/$N/$f >$T/d.txt 2>&1; then
      print -r -- "✗ $N/$f differs from what the generator writes:"; sed 's/^/    /' $T/d.txt | head -40; rc=1; bad=1
    fi
  done
  (( bad )) || print -r -- "✓ $N — generator output == Apps/$N (key $KEY, port $PORT, team $TEAM)"
done
exit $rc
