---
name: oracle-app
description: "Build an oracle's own Mac app from oracle-app-kit — an agent app like Neo, Pulse, Nexus (Work, Inbox, PRs, Issues, Memory, Map, Trace, widget, Share, MCP memory server) — and keep the portal (ARRA Oracles) building. Use when an oracle says 'build my app', 'oracle-app new', 'make an app for <oracle>', 'rebuild the apps', 'check my app'. Do NOT use for iOS App Store/TestFlight shipping or for the Chrome extension."
---

# /oracle-app — an oracle builds its own app

```
/oracle-app new      <Name> [--key k] [--repo org/repo] [--color #hex] [--symbol sf] [--tagline "…"] [--imagegen]
/oracle-app update   <Name>          regenerate generated files; keeps <Name>Extras.swift, icon, port, widget kind
/oracle-app panel    <Name> <title>  add an ExtraSection skeleton to <Name>Extras.swift
/oracle-app build    [<Name>…|--all] Release build + install + relaunch (herdr pane, install lock)
/oracle-app check    <Name>          the acceptance rows, one report
/oracle-app portal   build|check     the hub (ARRA Oracles): rebuild; verify the new app shows up
```

Works under Claude Code and Codex. Every step is a plain shell command below; slash-skills named here
(`/herdr-pane-run`, `/herdr-pr`, `/imagegen`) are conveniences with the fallback written next to them.

## 0. Where things are

```bash
KIT=$(ghq list -p --exact Soul-Brews-Studio/oracle-app-kit) || ghq get -p Soul-Brews-Studio/oracle-app-kit
ORACLE=$(git rev-parse --show-toplevel)             # the oracle's own repo — the app is ABOUT it
date +%-d%b-%a%Y | tr 'A-Z' 'a-z'                    # date slug for the worktree name
```

Never work in `$KIT`'s main checkout. Cut a worktree:
`git -C $KIT worktree add -b feat/app-<key> $KIT/wt/app-<key>-<oracle>-<date> origin/main`, then `K=` that path.

## 1. Preflight — stop with the exact step if one is missing (never fail mid-build)

| need | check | when missing (the human does this once per Mac) |
|---|---|---|
| Xcode + xcodegen | `xcodebuild -version && xcodegen --version` | `xcode-select --install; brew install xcodegen` |
| Rust | `command -v cargo` | `brew install rustup && rustup-init -y && . ~/.cargo/env` |
| signing team | `security find-identity -v -p codesigning` | Xcode → Settings → Accounts → sign in. Several teams: ask once, then `export ORACLE_APP_TEAM=<id>` |
| Screen Recording | `scripts/shot.sh` prints a window id | System Settings → Privacy & Security → Screen Recording → the terminal |
| herdr / maw (Work page) | `command -v herdr maw` | optional: without them Work shows "no herdr here" and that row passes |

## 2. `new`

1. **Identity from the oracle's repo, flags only override.**
   - repo: `git -C $ORACLE remote get-url origin` → `org/repo`. Checkout: `$ORACLE`.
   - Name: a Swift type name (`Athena`, `DustBoyPhd`). Key: default = portal rule, repo minus `-oracle`,
     lower-cased (`DustBoy-Phd-Oracle` → `dustboy-phd`). Never hand-pick a key that differs from that rule
     unless the portal should not match it.
   - colour: the oracle's CLAUDE.md design colour, else ask once. symbol + tagline: from its "I am" line.
   - refuse: `Apps/<Name>` exists, the key is used by another `Apps/*/app.yml`, the colour is another app's.
2. **Icon.** `design/icons/<Name>.png` if present. `--imagegen` (or an explicit yes): `/imagegen` an emblem on
   the dark squircle in the oracle colour, save as `design/icons/<Name>.png`. Otherwise the generator draws one.
   Look at it (Read the PNG) before going on.
3. **Generate**
   ```bash
   zsh $K/scripts/new-oracle-app.sh <Name> <org/repo> <checkout> '<#hex>' <sf.symbol> "<tagline>" \
       ${KEY:+--key $KEY} ${ORACLE_APP_TEAM:+--team $ORACLE_APP_TEAM}
   zsh $K/scripts/parity.sh           # the generator still matches Neo/Pulse/Nexus — must print ✓ for each
   ```
   The port is picked automatically (next free from 4791) and printed.
4. **Build + install** — minutes, so in a herdr pane, never a blocking call:
   ```bash
   herdr pane run <PANE> 'zsh '$K'/scripts/build.sh <Name> Oracles --install; RC=$?; \
     herdr agent prompt <ME> "PANE <PANE> oracle-app build rc=$RC
   $(herdr pane read <PANE> --source recent-unwrapped --lines 14 | tail -10)"'
   ```
   (no herdr: run `zsh $K/scripts/build.sh <Name> Oracles --install` in a second terminal.)
   rc 75 = another agent holds the install lock: it prints who and the wait command. Do not delete the lock
   while its pid is alive; a dead holder's lock is taken over automatically.
5. **Check** (section 3). Every row ✓, or fix and re-run — the failing row prints its own fix.
6. **PR.** Commit `Apps/<Name>/**`, `apps.yml`, `OracleApps.xcodeproj/project.pbxproj`, `design/icons/<Name>.png`
   and the check screenshots. Scrub first (section 5). Push, open a PR with the "Built by" block (`/herdr-pr`;
   fallback: oracle, model, worktree, branch, session id, herdr pane in the PR body). **Never merge it.**

## 3. `check <Name>` — what "built" means

```bash
zsh $K/skills/oracle-app/check.sh <Name>        # runs every row below, prints ✓/✗ and the fix per row
```

| row | how | pass |
|---|---|---|
| launches | `open "/Applications/<Name>.app" --args -oracleSection status`, then `pgrep -fl "<Name>.app/Contents/MacOS"` | running from `/Applications`, no new crash report |
| portal key | bundle id vs portal rule | `co.laris.oracle.<key>` == repo minus `-oracle`, lower-cased |
| MCP | `curl -s 127.0.0.1:<port>/health` | `ok` |
| widget | `pluginkit -m -i co.laris.oracle.<key>.widget` after one launch | registered (one retry) |
| CalVer | `PlistBuddy -c 'Print :ARRACalVer'` | today |
| parity | `scripts/parity.sh` | ✓ for every app |
| screenshots | `scripts/shot.sh <Name> <file> -- -oracleSection status|memory|map` | window shots, by window id |
| iOS compiles | `xcodebuild -scheme <Name> -destination 'generic/platform=iOS' build CODE_SIGNING_ALLOWED=NO` | builds |

Drive the app only by launch arguments (`-oracleSection status|inbox|prs|issues|memory|map|trace|settings`,
`-memoryAction batch|layout`, `-memoryQuery "<words>"`) and read its log
(`~/Library/Logs/ARRA Oracles/<Name>.log`). **Never click**: a synthetic click lands in the window a human is using.

## 4. `update`, `panel`, `build`, `portal`

- `update <Name>`: `new-oracle-app.sh … --update` with the identity read back from `<Name>Config.swift` (as
  `parity.sh` does). Keeps Extras, icon, port and the widget `kind` — renaming a kind leaves every placed widget
  as a grey placeholder for good.
- `panel <Name> <Title>`: add to `<Name>Extras.swift`
  `ExtraSection(id: "<slug>", title: "<Title>", symbol: "square.grid.2x2") { AnyView(<Title>Panel()) }` and a
  `struct <Title>Panel: View` stub in the same file.
- `build`: `scripts/build.sh <Schemes…> --install` (default all four).
- `portal build`: `scripts/build.sh Oracles --install`. `portal check`: `scripts/shot.sh "ARRA Oracles" hub.png`,
  confirm the new app's card under APPS; `curl -s 127.0.0.1:4790/health`.

## 5. Rules

- No `git push --force`, no push to main, never merge (a human does), temp files in `.tmp/`, long builds in a pane.
- The kit is **public**. Before committing: `rg -n -i 'token|secret|api[_-]?key|bearer|ghp_|sk-|/Users/[a-z]' <new files>`.
  Exactly one machine path is allowed: the `OracleConfig.mac("…")` line (the oracle's own checkout).
- Two agents: the install lock serialises `/Applications`. Tell the other agent (`herdr agent prompt`) before
  a long install anyway.
- Mac only. No App Store / TestFlight here.
