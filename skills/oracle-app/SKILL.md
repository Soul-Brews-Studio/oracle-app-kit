---
name: oracle-app
description: "Build an oracle's own Mac app from oracle-app-kit — an agent app like Neo, Pulse, Nexus (Work, Inbox, PRs, Issues, Memory, Map, Trace, widget, Share, MCP memory server) — and keep the portal (ARRA Oracles) building. Use when an oracle says 'build my app', 'oracle-app new', 'make an app for <oracle>', 'rebuild the apps', 'check my app'. Do NOT use for iOS App Store/TestFlight shipping or for the Chrome extension."
---

# /oracle-app — an oracle builds its own app

```
/oracle-app new      <Name> [--repo=org/repo] [--key=k] [--color=#hex] [--symbol=sf] [--tagline="…"] [--imagegen]
/oracle-app update   <Name>          regenerate generated files; keeps Extras, icon, key, port, team, widget kind
/oracle-app panel    <Name> <title>  add an ExtraSection skeleton to <Name>Extras.swift
/oracle-app build    [<Name>…]       Release build + install + relaunch-if-running (herdr pane, install lock)
/oracle-app check    <Name>          the acceptance rows, one report — never quits an app a human is using
/oracle-app portal   build|check     the hub (ARRA Oracles): rebuild; verify the new app shows up — never relaunched unasked
```

Works under Claude Code and Codex, in zsh (macOS default) and bash. Every step is a plain shell command below;
slash-skills named here (`/herdr-pr`, `/imagegen`) are conveniences with the fallback written next to them.

## 0. Where things are

```bash
KIT=$(ghq list -p --exact Soul-Brews-Studio/oracle-app-kit)
[ -n "$KIT" ] || { ghq get -p Soul-Brews-Studio/oracle-app-kit; KIT=$(ghq list -p --exact Soul-Brews-Studio/oracle-app-kit); }
SLUG=$(git remote get-url origin | sed -E 's#(\.git)?$##; s#.*github\.com[:/]##')    # the oracle's org/repo
ORACLE=$(git worktree list --porcelain | awk '/^worktree /{print $2; exit}')   # its MAIN checkout, even from a worktree:
[ -d "$ORACLE" ] || echo "run this inside the oracle's repo"                     # this path is baked into the app
# --repo=org/repo (building for another oracle): SLUG=org/repo; ORACLE=$(ghq list -p --exact "$SLUG")
#   (clone it first: ghq get -p "$SLUG"); read colour / symbol / tagline from $ORACLE/CLAUDE.md, not from here
```

Never work in `$KIT`'s main checkout. Cut a worktree:
`git -C $KIT worktree add -b feat/app-<key> $KIT/wt/app-<key>-<oracle>-<date> origin/main`, then `K=` that path.

## 1. Preflight — stop with the exact step if one is missing (never fail mid-build)

| need | check | when missing (the human does this once per Mac) |
|---|---|---|
| Xcode + xcodegen | `xcodebuild -version && xcodegen --version` | `xcode-select --install; brew install xcodegen` |
| Rust (the build finds it here too) | `PATH="/opt/homebrew/opt/rustup/bin:$HOME/.cargo/bin:$PATH" command -v cargo` | `brew install rustup && /opt/homebrew/opt/rustup/bin/rustup default stable` |
| uv (draws the icon), ripgrep | `command -v uv rg` | `brew install uv ripgrep` |
| signing team | the `OU=` of the signing certificate (below) | Xcode → Settings → Accounts → sign in |
| Screen Recording | `swift -e 'import CoreGraphics; print(CGPreflightScreenCaptureAccess())'` prints `true` | System Settings → Privacy & Security → Screen Recording → the terminal |
| herdr / maw (Work page) | `command -v herdr maw` | optional: without them the Work page is empty, which is correct |

The Team ID is the certificate's `OU`, **not** the id in parentheses that `find-identity` prints:
```bash
security find-identity -v -p codesigning                       # names, e.g. "Apple Development: Name (USERID)"
security find-certificate -c "Apple Development: <Name> (<USERID>)" -p | openssl x509 -noout -subject   # … OU=<TEAMID> …
```
The generator and `scripts/build.sh` read these themselves (`scripts/team.sh`): project.yml's team when a certificate
here has it, else this Mac's only team; with several teams and none of them project.yml's they refuse and print one
command per team — ask the human which, then `export ORACLE_APP_TEAM=<TEAMID>`. `--update` keeps an app's own team
unless `--team=` is given. The generator's ready line says where the team came from.

## 2. `new`

1. **Identity from the oracle's repo, flags only override.**
   - repo: `$SLUG`; checkout: `$ORACLE` (§0).
   - Name: a Swift type name (`Athena`, `DustBoyPhd`). Key: default = the portal's rule, repo minus `-oracle`,
     lower-cased, `_` and `.` made `-` (`DustBoy-Phd-Oracle` → `dustboy-phd`, `boon_v2-oracle` → `boon-v2`). A different
     key means the portal never matches the app.
   - colour: the oracle's CLAUDE.md design colour, else ask once. symbol + tagline: from its "I am" line.
   - The generator refuses, before writing anything: an existing `Apps/<Name>`, a key / colour / MCP port another app
     has, a port something else listens on, a non-Swift Name, a checkout path that is not an absolute existing folder,
     an empty symbol, a bad team.
2. **Icon.** `design/icons/<Name>.png` if present. `--imagegen` (or an explicit yes): `/imagegen` an emblem on the dark
   squircle in the oracle colour, saved as `design/icons/<Name>.png`. Otherwise the generator draws one. Look at it
   (open the PNG) before going on.
3. **Generate** — `--opt=value` is one word in zsh and bash alike:
   ```bash
   zsh $K/scripts/new-oracle-app.sh <Name> $SLUG "$ORACLE" '<#hex>' <sf.symbol> '<tagline>' \
       ${KEY:+--key=$KEY} ${ORACLE_APP_TEAM:+--team=$ORACLE_APP_TEAM}
   zsh $K/scripts/parity.sh           # the generator still matches every app — ✓ for each, or stop
   ```
   Single-quote the tagline (an apostrophe is `'\''`): a `$` or backtick copied from a CLAUDE.md line must not
   run in your shell. It prints the key, bundle id, MCP port (next free from 4791) and team.
4. **Build + install the new app only** — the portal finds it by bundle id, it needs no rebuild. Minutes, so in a
   herdr pane, never a blocking call:
   ```bash
   herdr pane run <PANE> 'ORACLE_APP_TEAM='${ORACLE_APP_TEAM:-}' zsh '$K'/scripts/build.sh <Name> --install; RC=$?; \
     herdr agent prompt <ME> "PANE <PANE> oracle-app build rc=$RC
   $(herdr pane read <PANE> --source recent-unwrapped --lines 14 | tail -10)"'
   ```
   (no herdr: run `zsh $K/scripts/build.sh <Name> --install` in a second terminal.)
   rc 75 = another agent holds the install lock: it prints who and a wait command that ends when that agent's process
   ends. Never delete the lock by hand; a dead holder's lock is taken over automatically.
5. **Check** (§3): `check.sh <Name> --deep --shots --relaunch` — the new app is yours to relaunch. It takes minutes
   (the model loads, the memory is embedded), so run it in a herdr pane like step 4:
   `herdr pane run <PANE> 'zsh '$K'/skills/oracle-app/check.sh <Name> --deep --shots --relaunch; RC=$?; herdr agent prompt <ME> "PANE <PANE> oracle-app check rc=$RC $(herdr pane read <PANE> --source recent-unwrapped --lines 60 | rg -v "^✓" | tail -40)"'`
   (only the green rows are dropped: every ✗ keeps the indented command that fixes it).
   Every row ✓, or fix and re-run; each ✗ prints its own fix. Add `--ios` once OracleKit builds for iOS (#46): on main today it does
   not (`HubViews.swift`, `GHIndex.swift`, `MapClusters.swift`, `Views.swift` use macOS-only API), so that row is ✗ for
   every app, the generated one included — not a defect of the new app.
6. **PR.** Commit `Apps/<Name>/**`, `apps.yml`, `OracleApps.xcodeproj/project.pbxproj`, `design/icons/<Name>.png`, and
   the screenshots `--shots` wrote to `build/shots/` (gitignored), copied under `docs/screenshots/<Name>/` — **not**
   under `Apps/<Name>/`, which is the app's source folder and would be bundled into the app:
   `mkdir -p $K/docs/screenshots/<Name> && cp $K/build/shots/<Name>-*.png $K/docs/screenshots/<Name>/` Scrub first (§5). Push, open a PR with the "Built by" block (`/herdr-pr`; fallback:
   oracle, model, worktree, branch, session id, herdr pane in the PR body). **Never merge it.**

## 3. `check <Name>` — what "built" means

```bash
zsh $K/skills/oracle-app/check.sh <Name>                 # read-mostly: launches the app only if it is not running
zsh $K/skills/oracle-app/check.sh <Name> --deep --shots --relaunch   # + Memory, Map, screenshots: QUITS and relaunches it
```

By default nothing is quit: a running copy is checked as it is (a human may be using it), a stopped one is launched.
`--deep` / `--shots` drive pages by launch argument, so they need `--relaunch` when the app was already running, and
they skip while another agent installs. `--no-launch` never launches or quits anything. A plain run covers the rows
down to parity; Memory, Map, screenshots and iOS need `--deep`, `--shots`, `--ios`.

| row | how | pass |
|---|---|---|
| portal key | bundle id vs the portal's rule (`HubParse.appKey`) | `co.laris.oracle.<key>` == repo minus `-oracle`, lower-cased, `_` `.` → `-` |
| app wires | `<Name>App.swift` | BundledANE, MapLayoutEngine, `MCPServer.serve(name: "<name>-memory", port: <port>)` |
| installed | `/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' /Applications/<Name>.app/Contents/Info.plist` | `co.laris.oracle.<key>`, display name `<Name>` |
| CalVer | `/usr/libexec/PlistBuddy -c 'Print :ARRACalVer' …/Info.plist` | today, Bangkok time |
| running | `pgrep -fl "<Name>.app/Contents/MacOS/<Name>"` | from `/Applications` |
| no crash | `~/Library/Logs/DiagnosticReports/{<Name>,<Name>Widget,<Name>Share}-*` | none since launch |
| MCP | `curl -s 127.0.0.1:<port>/health` | `"name":"<name>-memory"`, `"status":"ok"` |
| MCP search | POST `/mcp` `tools/call memory_search` | a result, not an error |
| Trace | `~/Library/Logs/ARRA Oracles/<Name>-queries.jsonl` | that exact query recorded as `source: mcp`, with its caller |
| widget | `pluginkit -m -v -i co.laris.oracle.<key>.widget` | registered from `/Applications/<Name>.app` |
| parity | `scripts/parity.sh` | ✓ for every app |
| Memory (`--deep`) | `-oracleSection memory -memoryAction batch -memoryQuery <name>` | `memory batch done` / `up to date`, then the search line with ≥1 hit (`ranked N`, `best P%`, both > 0) |
| Map (`--deep`) | `-oracleSection map -memoryAction layout` | `map layout: N docs in` or `map: N points in`, N > 0 |
| screenshots (`--shots`) | `scripts/shot.sh <Name> <file> -- -oracleSection <page>` | window shots, by window id |
| iOS (`--ios`) | `xcodebuild -scheme <Name> -destination 'generic/platform=iOS' build CODE_SIGNING_ALLOWED=NO` | builds — fails on main for every app until #46 |

Not covered by a row (look at the screenshots): the Work page's content, the sidebar's identity, and in the portal
that the APPS card opens the app and shows its sessions (a click — the human's to try).

Drive the app only by launch arguments — `-oracleSection memory`, `map`, `trace` or `settings` (anything else opens
Work), `-memoryAction batch` / `layout`, `-memoryQuery "<words>"` — and read its log,
`~/Library/Logs/ARRA Oracles/<Name>.log` (the hub's is `embed.log`). **Never click**: a synthetic click lands in the
window a human is using.

## 4. `update`, `panel`, `build`, `portal`

- `update <Name>`: `zsh $K/scripts/new-oracle-app.sh <the same 6 identity arguments> --update`. Key, port and team are
  read back from the app; Extras, icon and the widget `kind` are kept — renaming a kind leaves every placed widget a
  grey placeholder for good. `check.sh` prints the exact command on a ✗.
- `panel <Name> <Title>`: add to `<Name>Extras.swift`
  `ExtraSection(id: "<slug>", title: "<Title>", symbol: "square.grid.2x2") { AnyView(<Title>Panel()) }` and a
  `struct <Title>Panel: View` stub in the same file.
- `build`: `scripts/build.sh <Schemes…> --install` — names required with `--install`. Apps that were running are
  relaunched; the hub always is. Without `--install`, no names = build all four (nothing installed).
- `portal build`: `scripts/build.sh Oracles --install` — this relaunches the hub; say so to the human first.
- `portal check` — never relaunches the hub:
  ```bash
  for a in /Applications/*.app; do id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$a/Contents/Info.plist" 2>/dev/null)
    [[ $id == co.laris.oracle.* && $id != *.hub ]] && echo "${id#co.laris.oracle.}"; done      # the APPS cards
  curl -s 127.0.0.1:4790/health                                                                 # the hub's MCP
  zsh $K/scripts/shot.sh "ARRA Oracles" $K/build/shots/hub.png --as-is                         # its window, as it is
  ```

## 5. Rules

- No `git push --force`, no push to main, never merge (a human does), temp files in the kit's `.tmp/`, long builds in a pane.
- The kit is **public**. Before committing, scan the new files; exactly one machine path may remain, the
  `OracleConfig.mac("…")` line (the oracle's own checkout):
  `rg -n -i '\btoken\b\s*[:=]|secret|api[_-]?key|bearer\s|ghp_|\bsk-[a-z0-9]|/Users/|/home/|/opt/Code' <new files> | rg -v 'OracleConfig\.mac\('`
  must print nothing. Also: no other people's names, chats or data in screenshots.
- Two agents: the install lock (`$(getconf DARWIN_USER_TEMP_DIR)oracle-app-install.lock`, or `$ORACLE_APP_LOCK`; one per
  macOS user) serialises
  `/Applications`; `check.sh` and `shot.sh` will not relaunch during another agent's install. Still tell the other
  agent (`herdr agent prompt`) before a long install.
- Mac only. No App Store / TestFlight here.
