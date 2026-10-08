#if os(macOS)
import Foundation

/// Send a space's Claude agent to a saved machine and bring it back, its conversation included (Nat 2026-10-08:
/// "send … go and back", then "we can enable 2 places at a same time but we should different session id").
/// Send forks: this Mac's agent keeps running, the far side resumes the same conversation under a new session id.
/// Bring back moves: the far agent stops, its transcript comes home, this Mac resumes it in the pane it left.
/// The steps are two shell scripts, proven by hand on transcriber-oracle m5 → white → m5 before they came here;
/// the app writes them to Application Support and runs them, so they can be run by hand from there too.
public enum Ferry {
    /// One send, remembered so Bring back knows where it came from (a far worktree maps to this Mac's checkout).
    public struct Leg: Codable, Hashable, Sendable {
        public let target: String          // the saved machine's ssh target
        public let session: String         // its herdr session
        public let far: String             // the folder it landed in there
        public let localSession: String    // this Mac's herdr session it left
        public let cwd: String             // this Mac's folder
        public let label: String
        public let at: Date
    }

    static var dir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ARRA Oracles/ferry")
    }
    static var ledgerURL: URL { dir.appendingPathComponent("legs.json") }

    public static func legs() -> [Leg] {
        guard let d = try? Data(contentsOf: ledgerURL) else { return [] }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        return (try? dec.decode([Leg].self, from: d)) ?? []
    }

    static func remember(_ leg: Leg) {
        var all = legs().filter { !($0.target == leg.target && $0.session == leg.session && $0.far == leg.far) }
        all.append(leg)
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601; enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? enc.encode(all).write(to: ledgerURL, options: .atomic)
    }

    /// Writes a script where it can run (again, when the app's copy changed); its path.
    static func install(_ name: String, _ body: String) -> String? {
        let url = dir.appendingPathComponent(name)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if (try? String(contentsOf: url, encoding: .utf8)) != body {
            guard (try? body.write(to: url, atomically: true, encoding: .utf8)) != nil else { return nil }
        }
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url.path
    }

    /// The far folder a send printed (`FERRY-FAR <path>`), when it landed in a worktree rather than the same path.
    static func far(in log: String) -> String? {
        log.split(separator: "\n").first { $0.hasPrefix("FERRY-FAR ") }.map { String($0.dropFirst(10)) }
    }

    // The launch flags both scripts keep: whitelisted, so a brief passed as a prompt never rides along; deduplicated.
    static let flagsAwk = #"""
    awk 'keep { k=prev" "$0; if (!(k in seen)) { seen[k]=1; printf "%s %s ", prev, $0 }; keep=0; next }
      $0=="--dangerously-skip-permissions" || $0 ~ /^--(channels|model|permission-mode)=/ { if (!($0 in seen)) { seen[$0]=1; printf "%s ", $0 }; next }
      $0=="--channels" || $0=="--model" || $0=="--permission-mode" { prev=$0; keep=1; next }'
    """#

    static let send = #"""
    #!/usr/bin/env bash
    # ferry-send.sh <local-session> <cwd> <ssh-target> <remote-session> <label>
    # Written by ARRA Oracles (OracleKit Hub.Ferry.swift): edit it there.
    # Forks the Claude agent running in <cwd> into <remote-session> on <ssh-target>, conversation included.
    # This Mac's agent keeps running; the far side resumes under a new session id. Stops on anything it should
    # not decide, printing the command that fixes it.
    set -uo pipefail
    export PATH="$HOME/.local/bin:$HOME/.bun/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
    LS=$1; N=$2; H=$3; SESS=$4; LABEL=$5
    STAMP=$(date +%Y%m%d-%H%M); HN=$(hostname -s | tr '[:upper:]' '[:lower:]')
    E=$(printf %s "$N" | sed 's#[/.]#-#g')
    ssh_w() { ssh -o BatchMode=yes -o ConnectTimeout=8 "$H" "$@"; }
    say() { printf '  %-10s %s\n' "$1" "$2"; }
    fail() { echo "  ✗ $1"; shift; for c in "$@"; do echo "    $c"; done; exit 1; }
    echo "--- $LABEL → $H ($SESS)"

    # 1. this Mac's agent: its session (from herdr), its launch flags, its repo and commit
    ID=$(herdr --session "$LS" pane list 2>/dev/null | jq -r --arg c "$N" '[.result.panes[] | select(.cwd==$c and .agent=="claude")][0].agent_session.value // empty')
    PID=; for p in $(pgrep -x claude); do [ "$(lsof -a -p "$p" -d cwd -Fn 2>/dev/null | sed -n 's/^n//p')" = "$N" ] && PID=$p; done
    [ -n "$ID" ] && [ -n "$PID" ] || fail "no Claude agent with a saved session in $N" "herdr --session $LS pane list | jq '.result.panes[] | select(.cwd==\"$N\")'"
    FLAGS=$(ps -ww -o command= -p "$PID" | tr ' ' '\n' | FLAGS_AWK)
    REPO=$(cd "$N" && git rev-parse --path-format=absolute --git-common-dir | sed 's#/\.git$##'); NAME=$(basename "$REPO")
    BRANCH=$(git -C "$N" branch --show-current); HEAD5=$(git -C "$N" rev-parse HEAD)
    say here "pid $PID · session $ID"
    say flags "${FLAGS:-none}"
    git -C "$N" fetch -q origin 2>/dev/null
    [ -n "$(git -C "$N" branch -r --contains "$HEAD5" 2>/dev/null)" ] || fail "commit ${HEAD5:0:8} is not on origin, so $H cannot fetch it" "git -C $N push -u origin $BRANCH"

    # 2. where it lands: the same folder when the checkout there can match this Mac's commit; else a new worktree
    F=$(ssh_w "bash -s" <<EOF
    same() { cd "$N" 2>/dev/null && git rev-parse --git-dir >/dev/null 2>&1 || return 1; git fetch -q origin
      [ "\$(git branch --show-current)" = "$BRANCH" ] && [ \$(git status --porcelain --untracked-files=no | wc -l) -eq 0 ] && git merge -q --ff-only $HEAD5 >/dev/null 2>&1
      [ "\$(git rev-parse HEAD)" = "$HEAD5" ] && [ \$(git status --porcelain --untracked-files=no | wc -l) -eq 0 ]; }
    if same; then echo "$N"; exit; fi
    [ -d "$REPO/.git" ] || { echo NOREPO; exit; }
    git -C "$REPO" fetch -q origin
    if [ "$N" != "$REPO" ] && [ ! -e "$N" ] && git -C "$REPO" worktree add -q "$N" "$BRANCH" >/dev/null 2>&1 && same; then echo "$N"; exit; fi
    W="$REPO/wt/ferry-from-$HN-$STAMP"
    git -C "$REPO" worktree add -q -b "ferry/from-$HN-$STAMP" "\$W" $HEAD5 >/dev/null 2>&1 && echo "\$W" || echo NOWT
    EOF
    )
    case "$F" in
      NOREPO|"") fail "$REPO is not on $H" "ssh $H 'ghq get \$(git -C $REPO remote get-url origin)'" ;;
      NOWT) fail "could not add a worktree of $NAME on $H" "ssh $H 'git -C $REPO worktree list'" ;;
    esac
    EF=$(printf %s "$F" | sed 's#[/.]#-#g')
    [ "$F" = "$N" ] && say lands "$F (same folder, at ${HEAD5:0:8})" || say lands "$F (a worktree: the folder there holds other work)"

    # 3. what git does not carry: the agent's new vault files (≤5 MB each), .envrc, the transcript
    U=$(git -C "$N" status --porcelain | sed -n 's/^?? //p' | tr '\n' ' ')
    ( cd "$N" && rsync -a --ignore-existing --max-size=5m -R -e "ssh -o BatchMode=yes" $U .envrc "$H:$F/" 2>/dev/null )
    # a copy of this id already there is from an earlier trip, and nothing writes it now (bring back stopped it): keep it
    # aside, then send this Mac's, which is the newer (--ignore-existing would resume the stale one)
    ssh_w "mkdir -p .claude/projects/$EF; f=.claude/projects/$EF/$ID.jsonl; [ -e \$f ] && mv \$f \$f.before-$STAMP; true"
    rsync -a -e "ssh -o BatchMode=yes" "$HOME/.claude/projects/$E/$ID.jsonl" "$H:.claude/projects/$EF/" \
      || fail "the transcript did not copy" "rsync -av $HOME/.claude/projects/$E/$ID.jsonl $H:.claude/projects/$EF/"
    [ -d "$HOME/.claude/projects/$E/$ID" ] && rsync -a --ignore-existing -e "ssh -o BatchMode=yes" "$HOME/.claude/projects/$E/$ID" "$H:.claude/projects/$EF/"
    say history "$(wc -l < "$HOME/.claude/projects/$E/$ID.jsonl" | tr -d ' ') lines"

    # 4. the agent's Claude token must load there; an .envrc without one is replaced by this Mac's (old copy kept)
    tok() { ssh_w "bash -lc 'direnv allow $F >/dev/null 2>&1; cd $F && direnv exec . sh -c \"test -n \\\"\\\$CLAUDE_CODE_OAUTH_TOKEN\\\" && echo \\\${CLAUDE_TOKEN_NAME:-set}\" 2>/dev/null | tail -1'" 2>/dev/null; }
    T=$(tok)
    if [ -z "$T" ] && grep -q CLAUDE_CODE_OAUTH_TOKEN "$N/.envrc" 2>/dev/null; then
      ssh_w "mkdir -p ~/.cache/ferry-backup/$NAME && cp -p $F/.envrc ~/.cache/ferry-backup/$NAME/.envrc.$STAMP 2>/dev/null; true"
      rsync -a -e "ssh -o BatchMode=yes" "$N/.envrc" "$H:$F/.envrc"; T=$(tok)
      say envrc "the one there set no token: replaced by this Mac's (old copy in ~/.cache/ferry-backup/$NAME/)"
    fi
    [ -n "$T" ] || fail "no Claude token loads on $H in $F" "ssh $H 'cd $F && direnv exec . env | grep -c CLAUDE_CODE_OAUTH_TOKEN'"
    say token "$T"

    # 5. a workspace in the far session, the fork started in it; a Discord bot gets its state dir when the far side has one
    DS=""; case "$FLAGS" in *discord*) ssh_w "test -s ~/.claude/channels/$NAME/.env" && DS="DISCORD_STATE_DIR=\$HOME/.claude/channels/$NAME";; esac
    P=$(ssh_w "bash -l -s" 2>/dev/null <<EOF
    WS=\$(herdr --session $SESS workspace create --cwd "$F" --label "$LABEL" --no-focus 2>/dev/null | jq -r .result.workspace.workspace_id)
    P=\$(herdr --session $SESS pane list --workspace \$WS 2>/dev/null | jq -r '.result.panes[0].pane_id')
    herdr --session $SESS pane send-text \$P 'direnv exec . env $DS claude $FLAGS--resume $ID --fork-session' >/dev/null
    herdr --session $SESS pane send-keys \$P Enter >/dev/null
    echo \$P
    EOF
    )
    [ -n "$P" ] && [ "$P" != null ] || fail "could not open a workspace in $SESS on $H" "herdr machine list --json | jq '.[] | select(.session==\"$SESS\")'"
    say there "pane $P${DS:+ · Discord state dir}"

    # 6. first-run dialogs: trust the folder (checked before Enter: the default is "No, exit"); refuse new project MCP servers
    R=$(ssh_w "bash -l -s" 2>/dev/null <<EOF
    S="herdr --session $SESS pane"
    for i in \$(seq 40); do
      v=\$(\$S read $P --source visible 2>/dev/null)
      if echo "\$v" | grep -q 'Yes, I trust this folder'; then
        \$S send-keys $P Down >/dev/null; sleep 0.8
        \$S read $P --source visible | grep -q '❯ Yes, I trust this folder' && \$S send-keys $P Enter >/dev/null && echo trusted
      elif echo "\$v" | grep -q 'new MCP servers found'; then \$S send-keys $P Escape >/dev/null; echo mcp-refused
      elif echo "\$v" | grep -qE 'bypass permissions|for shortcuts|⏵⏵'; then echo ready; exit
      fi; sleep 1
    done; echo not-ready
    EOF
    )
    say start "$(echo $R)"

    # 7. Claude marks a Discord channel failed at launch without trying it; /mcp → Reconnect starts it
    if [ -n "$DS" ]; then
      ssh_w "bash -l -s" >/dev/null 2>&1 <<EOF
    S="herdr --session $SESS pane"
    \$S send-text $P '/mcp' ; \$S send-keys $P Enter ; sleep 2
    n=\$(\$S read $P --source visible | grep -E '^ *(❯ )?(✔|✘|⚠) ' | grep -n 'plugin:discord' | cut -d: -f1)
    if [ -n "\$n" ]; then for i in \$(seq \$((n - 1))); do \$S send-keys $P Down; sleep 0.2; done; \$S send-keys $P Enter; sleep 1; \$S send-keys $P Enter; sleep 6; fi
    \$S send-keys $P Escape; sleep 0.3; \$S send-keys $P Escape
    EOF
      C=$(ssh_w "for p in \$(pgrep -u \$(id -u) -f 'resume $ID'); do pgrep -P \$p -af discord; done | head -1")
      say discord "${C:+connected}${C:-not connected: in $SESS on $H open /mcp and Reconnect plugin:discord:discord}"
    fi
    echo "FERRY-FAR $F"
    echo "  ✓ $LABEL forked to $H ($SESS) · herdr --remote $H --session $SESS"
    """#

    static let back = #"""
    #!/usr/bin/env bash
    # ferry-back.sh <local-session> <cwd> <ssh-target> <remote-session> <far-cwd> [<label>]
    # Written by ARRA Oracles (OracleKit Hub.Ferry.swift): edit it there.
    # Brings a fork home. Default MOVE: the far agent stops (first, so its copy is final), its transcript comes
    # home, this Mac's stale agent in that folder stops, the far conversation resumes here, the far workspace closes.
    # KEEP=1: the far agent keeps running and this Mac resumes it as a new fork.
    set -uo pipefail
    export PATH="$HOME/.local/bin:$HOME/.bun/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
    LS=$1; N=$2; H=$3; SESS=$4; F=$5; LABEL=${6:-$(basename "$2")}
    E=$(printf %s "$N" | sed 's#[/.]#-#g'); EF=$(printf %s "$F" | sed 's#[/.]#-#g')
    ssh_w() { ssh -o BatchMode=yes -o ConnectTimeout=8 "$H" "$@"; }
    say() { printf '  %-10s %s\n' "$1" "$2"; }
    fail() { echo "  ✗ $1"; shift; for c in "$@"; do echo "    $c"; done; exit 1; }
    echo "--- $LABEL ← $H ($SESS)"

    # 1. the far agent: its process, the transcript it writes now, its pane, its launch flags
    R=$(ssh_w "bash -l -s" 2>/dev/null <<EOF
    pid=; for x in \$(pgrep -u \$(id -u) -x claude); do [ "\$(readlink /proc/\$x/cwd)" = "$F" ] && pid=\$x; done
    [ -n "\$pid" ] || { echo NONE; exit; }
    start=\$(stat -c %Y /proc/\$pid)
    id=\$(for f in \$(ls -t ~/.claude/projects/$EF/*.jsonl 2>/dev/null); do [ \$(stat -c %Y \$f) -ge \$start ] && { basename \$f .jsonl; break; }; done)
    pane=\$(herdr --session $SESS pane list 2>/dev/null | jq -r --arg c "$F" '[.result.panes[] | select(.cwd==\$c)][0].pane_id')
    echo "\$pid \${id:-NOID} \$pane"
    tr '\0' '\n' < /proc/\$pid/cmdline
    EOF
    )
    read -r WPID X WPANE <<<"$(echo "$R" | head -1)"
    FLAGS=$(echo "$R" | tail -n +2 | FLAGS_AWK)   # filtered here: inside the heredoc its $0 would expand on this Mac
    [ "$WPID" = NONE ] && fail "no Claude agent runs in $F on $H" "ssh $H 'herdr --session $SESS pane list | jq -r .result.panes[].cwd'"
    [ "$X" = NOID ] && fail "the far fork has written nothing yet (a fork's transcript appears with its first message)" "herdr --remote $H --session $SESS   # talk to it once, then bring it back"
    say there "pid $WPID · pane $WPANE · fork $X"

    # 2. MOVE: stop it first, so the copy below is final (an exit appends a cost-state line)
    if [ -z "${KEEP:-}" ]; then
      ssh_w "bash -l -s" >/dev/null 2>&1 <<EOF
    herdr --session $SESS pane send-text $WPANE '/exit'; herdr --session $SESS pane send-keys $WPANE Enter
    for i in \$(seq 30); do kill -0 $WPID 2>/dev/null || break; sleep 0.5; done
    EOF
      ssh_w "kill -0 $WPID 2>/dev/null" && fail "the far agent did not exit" "ssh $H 'herdr --session $SESS pane send-keys $WPANE C-c'"
      say there "agent stopped"
    fi

    # 3. its transcript (and subagents) come home, under this Mac's folder
    mkdir -p "$HOME/.claude/projects/$E"
    rsync -a -e "ssh -o BatchMode=yes" "$H:.claude/projects/$EF/$X.jsonl" "$HOME/.claude/projects/$E/" || fail "the transcript did not copy" "rsync -av $H:.claude/projects/$EF/$X.jsonl $HOME/.claude/projects/$E/"
    ssh_w "test -d ~/.claude/projects/$EF/$X" && rsync -a -e "ssh -o BatchMode=yes" "$H:.claude/projects/$EF/$X" "$HOME/.claude/projects/$E/"
    say history "$(wc -l < "$HOME/.claude/projects/$E/$X.jsonl" | tr -d ' ') lines here"

    # 4. this Mac: the pane it left (a new space if that one closed), the stale agent stopped, the conversation resumed
    MP=$(herdr --session "$LS" pane list 2>/dev/null | jq -r --arg c "$N" '([.result.panes[] | select(.cwd==$c and .agent=="claude")] + [.result.panes[] | select(.cwd==$c)])[0].pane_id // empty')
    if [ -z "$MP" ]; then
      WS=$(herdr --session "$LS" workspace create --cwd "$N" --label "$LABEL" --no-focus 2>/dev/null | jq -r .result.workspace.workspace_id)
      MP=$(herdr --session "$LS" pane list --workspace "$WS" 2>/dev/null | jq -r '.result.panes[0].pane_id // empty')
      [ -n "$MP" ] || fail "no pane here for $N" "herdr --session $LS workspace create --cwd $N --label $LABEL"
      say here "opened a new space for it ($MP)"
    fi
    MPID=; for p in $(pgrep -x claude); do [ "$(lsof -a -p "$p" -d cwd -Fn 2>/dev/null | sed -n 's/^n//p')" = "$N" ] && MPID=$p; done
    if [ -n "$MPID" ]; then
      herdr --session "$LS" pane send-text "$MP" '/exit' >/dev/null; herdr --session "$LS" pane send-keys "$MP" Enter >/dev/null
      for i in $(seq 30); do kill -0 "$MPID" 2>/dev/null || break; sleep 0.5; done
      kill -0 "$MPID" 2>/dev/null && fail "this Mac's agent $MPID did not exit" "herdr --session $LS pane send-keys $MP C-c"
      say here "stale agent $MPID stopped in $MP"
    fi
    FORK=""; [ -n "${KEEP:-}" ] && FORK=" --fork-session"
    herdr --session "$LS" pane run "$MP" "claude ${FLAGS}--resume $X$FORK" >/dev/null
    say here "resumed $X in $MP${FORK:+ as a new fork}"

    # 5. MOVE: the far workspace closes last, once this Mac runs it; a ferry worktree stays on disk
    if [ -z "${KEEP:-}" ]; then
      ssh_w "bash -lc 'herdr --session $SESS workspace close ${WPANE%%:*}'" >/dev/null 2>&1 && say there "workspace ${WPANE%%:*} closed"
      case "$F" in */wt/ferry-from-*) say there "worktree $F kept on disk";; esac
    fi
    echo "  ✓ $LABEL back here · herdr --session $LS pane read $MP --source recent --lines 20"
    """#

    static func script(_ body: String) -> String { body.replacingOccurrences(of: "FLAGS_AWK", with: flagsAwk.trimmingCharacters(in: .whitespacesAndNewlines)) }
}

/// What a send or a bring-back printed, for the sheet that shows it.
public struct FerryRun: Identifiable, Sendable {
    public let id = UUID()
    public let title: String
    public let ok: Bool
    public let log: String
}

extension HubStore {
    /// The saved machine a local session mirrors: the same session name (m5 laris-co → white's laris-co).
    public func mirror(of session: String) -> RemoteSession? {
        remotes.first { $0.session == session && $0.isSafe }
    }

    /// Fork a space's agent to a saved machine.
    public func send(_ space: HubSpace, to r: RemoteSession) async -> FerryRun {
        let title = "Send \(space.label) to \(r.label ?? r.host)"
        guard let cwd = space.checkout, let path = Ferry.install("ferry-send.sh", Ferry.script(Ferry.send)) else {
            return FerryRun(title: title, ok: false, log: "No folder for this space, or the script could not be written to \(Ferry.dir.path).")
        }
        let out = await Shell.capture("bash", [path, space.session, cwd, r.target, r.session, space.label], timeout: 300)
        let ok = out?.status == 0
        if ok, let log = out?.out {
            Ferry.remember(Ferry.Leg(target: r.target, session: r.session, far: Ferry.far(in: log) ?? cwd,
                                     localSession: space.session, cwd: cwd, label: space.label, at: Date()))
        }
        await refresh(remotes: true)
        return FerryRun(title: title, ok: ok, log: out?.out ?? "bash did not start: \(path)")
    }

    /// Where a far folder came from, if this Mac sent it: its folder and session here.
    public func home(of r: RemoteSession, far cwd: String) -> Ferry.Leg? {
        Ferry.legs().last { $0.target == r.target && $0.session == r.session && $0.far == cwd }
    }

    /// The far folder of a remote workspace's Claude agent, when it has one.
    public func agentFolder(_ r: RemoteSession, workspace: String) -> String? {
        remoteState[r.id]?.agentList.first { $0.workspace == workspace && $0.kind == "claude" }?.cwd
    }

    /// Bring a remote workspace's agent home: to the folder it was sent from, or the same path here.
    public func bringBack(_ r: RemoteSession, workspace: String, label: String) async -> FerryRun {
        let title = "Bring \(label) back from \(r.label ?? r.host)"
        guard let far = agentFolder(r, workspace: workspace), let path = Ferry.install("ferry-back.sh", Ferry.script(Ferry.back)) else {
            return FerryRun(title: title, ok: false, log: "No Claude agent found in that workspace on \(r.shortTarget). Refresh, then try again.")
        }
        let leg = home(of: r, far: far)
        let args = [path, leg?.localSession ?? r.session, leg?.cwd ?? far, r.target, r.session, far, leg?.label ?? label]
        let out = await Shell.capture("bash", args, timeout: 300)
        await refresh(remotes: true)
        return FerryRun(title: title, ok: out?.status == 0, log: out?.out ?? "bash did not start: \(path)")
    }
}
#endif
