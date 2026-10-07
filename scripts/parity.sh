#!/usr/bin/env zsh
# parity.sh [<Name> …]  — the generator must produce what the hand-tuned apps are.
# For each app (default: every Apps/* with a <Name>Config.swift except Hub), read its identity back from
# <Name>Config.swift / <Name>App.swift / app.yml, regenerate it into a scratch copy of the kit, and diff the
# generated files against the real ones. Exit 0 = no difference anywhere.
set -e
R=${0:A:h}/..; R=${R:A}
names=("$@")
if (( ! $#names )); then for d in $R/Apps/*(/); do [ -f $d/${d:t}Config.swift ] && names+=(${d:t}); done; fi
T=$(mktemp -d "${TMPDIR:-/tmp}/oracle-parity.XXXX"); trap 'rm -rf $T' EXIT
rsync -a --exclude build --exclude .git --exclude wt --exclude '*/target' $R/ $T/
rc=0
for N in $names; do
  C=$R/Apps/$N/${N}Config.swift
  get() { sed -n "s/.*$1: \"\\([^\"]*\\)\".*/\\1/p" $C | head -1; }
  SLUG=$(get repoSlug); HEX=$(get colorHex); SYM=$(get symbol); TAG=$(get tagline)
  LP=$(sed -n 's/.*OracleConfig.mac("\([^"]*\)").*/\1/p' $C | head -1)
  PORT=$(rg -o --no-filename 'port: [0-9]+' $R/Apps/$N/${N}App.swift | sed 's/port: //' | head -1)
  KEY=$(sed -n 's/^ *PRODUCT_BUNDLE_IDENTIFIER: co\.laris\.oracle\.\([a-z0-9-]*\)$/\1/p' $R/Apps/$N/app.yml | head -1)
  rm -rf $T/Apps/$N
  (cd $T && zsh scripts/new-oracle-app.sh $N $SLUG $LP $HEX $SYM "$TAG" --key $KEY --port $PORT --no-regen >/dev/null)
  bad=0
  for f in ${N}App.swift ${N}Config.swift app.yml Widget/${N}Widget.swift Share/ShareViewController.swift ${N}.entitlements Widget/${N}Widget.entitlements; do
    if ! diff -u $R/Apps/$N/$f $T/Apps/$N/$f >$T/d.txt; then
      echo "✗ $N/$f differs from what the generator writes:"; sed 's/^/    /' $T/d.txt | head -40; rc=1; bad=1
    fi
  done
  (( bad )) || echo "✓ $N — generator output == Apps/$N (key $KEY, port $PORT)"
done
exit $rc
