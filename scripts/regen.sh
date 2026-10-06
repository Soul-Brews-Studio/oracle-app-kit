#!/usr/bin/env zsh
# Rebuild apps.yml (one include per Apps/*/app.yml) and regenerate the Xcode project.
set -e
R=${0:A:h}/..; cd $R
{ echo "include:"; for f in Apps/*/app.yml(N); do echo "  - path: $f"; echo "    relativePaths: false"; done; } > apps.yml
xcodegen generate --quiet && echo "xcodegen ok ($(ls -d Apps/*/ | wc -l | tr -d ' ') apps)"
