# install-lock.sh — sourced. One installer of /Applications/{ARRA Oracles,Neo,Pulse,Nexus,…}.app at a time.
# Two agents installing at once clobbered each other (2026-10-07). mkdir is atomic; the holder's pid, who, branch and
# start time are written inside. The lock is per macOS user ($TMPDIR): every agent of that user shares it.
#   lock_take "<command to retry>"  → 0 = held by us; 1 = someone alive holds it (prints who + the wait command)
#   lock_held                       → 0 when a live holder other than us has it (shot.sh / check.sh ask before relaunching)
#   lock_drop                       → releases it, only if it is ours
# The CALLER sets the traps right after lock_take — in zsh an EXIT trap set inside a function fires when the function
# returns, and a signal trap that does not exit lets the script carry on:
#   trap lock_drop EXIT; trap 'lock_drop; exit 130' INT TERM HUP
# the per-user temp folder from the system, not $TMPDIR (unset under some launchers): every agent of one user agrees
LOCK_DIR=${ORACLE_APP_LOCK:-$(getconf DARWIN_USER_TEMP_DIR 2>/dev/null || print -r -- ${TMPDIR:-/tmp}/)oracle-app-install.lock}
_LOCK_KIT=${${(%):-%x}:A:h:h}   # the kit this file belongs to (for the branch shown to a waiter), wherever the caller cd's
lock_held() {
  local pid=$(cat $LOCK_DIR/pid 2>/dev/null)
  [[ -n $pid && $pid != $$ ]] && kill -0 $pid 2>/dev/null
}
lock_take() {
  local retry=${1:-} who=${ORACLE_APP_WHO:-${HERDR_PANE_ID:-$USER}} br=$(git -C $_LOCK_KIT branch --show-current 2>/dev/null)
  local waited=0 tries=0 pid age ino grave extra
  while ! mkdir $LOCK_DIR 2>/dev/null; do
    # gone again between our mkdir and this test (its holder just released it): try once more before blaming the folder
    [ -d $LOCK_DIR ] || { mkdir $LOCK_DIR 2>/dev/null && break; print -r -- "✗ cannot create the install lock $LOCK_DIR — is ${LOCK_DIR:h} writable?   ls -ld '${LOCK_DIR:h}'"; return 1; }
    # only ever take over a directory that is one of OUR locks (pid / who / branch / since, nothing else)
    extra=(${(f)"$(ls -A $LOCK_DIR 2>/dev/null | rg -v -x 'pid|who|branch|since')"})
    [[ -n ${extra[1]:-} ]] && { print -r -- "✗ $LOCK_DIR exists and is not an install lock (holds ${extra[1]}) — point ORACLE_APP_LOCK elsewhere:  export ORACLE_APP_LOCK=\${TMPDIR:-/tmp}/oracle-app-install.lock"; return 1; }
    ino=$(stat -f %i $LOCK_DIR 2>/dev/null)   # sampled BEFORE the staleness verdict, re-checked under the takeover mutex
    pid=$(cat $LOCK_DIR/pid 2>/dev/null); age=$(( $(date +%s) - $(stat -f %m $LOCK_DIR 2>/dev/null || date +%s) ))
    if [[ -z $pid ]] && (( age < 10 && waited < 15 )); then sleep 1; waited=$((waited + 1)); continue; fi   # being created right now
    if [[ -n $pid ]] && kill -0 $pid 2>/dev/null; then
      print -r -- "✗ install lock held by $(cat $LOCK_DIR/who 2>/dev/null) ($(cat $LOCK_DIR/branch 2>/dev/null)) since $(cat $LOCK_DIR/since 2>/dev/null), pid $pid"
      print -r -- "  wait for it:  while kill -0 $pid 2>/dev/null; do sleep 5; done; $retry"
      return 1
    fi
    # stale (its holder died without releasing it). Never move a lock: under a short takeover mutex (one taker at a
    # time), re-check that it is still the very lock judged stale — same inode, same dead pid — and only then remove it.
    if mkdir $LOCK_DIR.takeover 2>/dev/null; then
      if [[ $(stat -f %i $LOCK_DIR 2>/dev/null) == $ino && $(cat $LOCK_DIR/pid 2>/dev/null) == $pid ]] && ! { [[ -n $pid ]] && kill -0 $pid 2>/dev/null; }; then
        print -r -- "! stale install lock from $(cat $LOCK_DIR/who 2>/dev/null) at $(cat $LOCK_DIR/since 2>/dev/null) (pid ${pid:-none} gone) — taking it over"
        rm -rf $LOCK_DIR
      fi
      rmdir $LOCK_DIR.takeover 2>/dev/null
    elif (( $(date +%s) - $(stat -f %m $LOCK_DIR.takeover 2>/dev/null || date +%s) > 30 )); then
      rmdir $LOCK_DIR.takeover 2>/dev/null   # a takeover mutex left by a taker that died mid-takeover
    fi
    tries=$((tries + 1))
    (( tries > 20 )) && { print -r -- "✗ cannot take over the stale install lock $LOCK_DIR — another taker holds $LOCK_DIR.takeover (cleared by itself after 30 s); see who:  ls -ld '$LOCK_DIR' '$LOCK_DIR.takeover'; cat '$LOCK_DIR/who'"; return 1; }
    sleep 0.2
  done
  print -r -- $$ > $LOCK_DIR/pid; print -r -- $who > $LOCK_DIR/who; print -r -- $br > $LOCK_DIR/branch; date '+%H:%M:%S' > $LOCK_DIR/since
}
lock_drop() { [[ $(cat $LOCK_DIR/pid 2>/dev/null) == $$ ]] && rm -rf $LOCK_DIR; return 0 }
