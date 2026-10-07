# team.sh — sourced. Which Apple signing team builds here: the Team ID is the OU of a signing certificate on this Mac
# (security find-identity prints the user id in parentheses, not the team).
#   cert_teams      → the Team IDs of every valid signing identity in the keychain, one per line, sorted, unique
#   project_team    → DEVELOPMENT_TEAM in the kit's project.yml
cert_teams() {
  local n
  security find-identity -v -p codesigning 2>/dev/null | sed -n 's/.*"\(.*\)"$/\1/p' | while IFS= read -r n; do
    security find-certificate -c "$n" -p 2>/dev/null | openssl x509 -noout -subject 2>/dev/null \
      | sed -n 's/.*OU *= *\([A-Z0-9][A-Z0-9]*\).*/\1/p'
  done | sort -u
}
project_team() { sed -n 's/^ *DEVELOPMENT_TEAM: *//p' ${${(%):-%x}:A:h:h}/project.yml | head -1 }
