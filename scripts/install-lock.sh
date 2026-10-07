# install-lock.sh — sourced. One installer of /Applications/{ARRA Oracles,Neo,Pulse,Nexus,…}.app at a time.
# Two agents installing at once clobbered each other (2026-10-07). mkdir is atomic; the holder's pid, who, branch and
# start time are written inside. The lock is per macOS user ($TMPDIR): every agent of that user shares it.
#   lock_take "<command to retry>"  → 0 = held by us; 1 = someone alive holds it (prints who + the wait command)
#   lock_held                       → 0 when a live holder other than us has it (shot.sh / check.sh ask before relaunching)
#   lock_drop                       → releases it, only if it is ours
# The CALLER sets the traps right after lock_take — in zsh an EXIT trap set inside a function fires when the function
# returns, and a signal trap that does not exit lets the script carry on:
#   trap lock_drop EXIT; trap 'lock_drop; exit 130' INT TERM HUP
LOCK_DIR=${ORACLE_APP_LOCK:-${TMPDIR:-/tmp}/oracle-app-install.lock}
lock_held() {
  local pid=$(cat $LOCK_DIR/pid 2>/dev/null)
  [[ -n $pid && $pid != $$ ]] && kill -0 $pid 2>/dev/null
}
lock_take() {
  local retry=${1:-} who=${ORACLE_APP_WHO:-${HERDR_PANE_ID:-$USER}} br=$(git -C ${ZSH_ARGZERO:A:h}/.. branch --show-current 2>/dev/null)
  local waited=0 tries=0 pid age ino grave extra
  while ! mkdir $LOCK_DIR 2>/dev/null; do
    [ -d $LOCK_DIR ] || { print -r -- "✗ cannot create the install lock $LOCK_DIR — is ${LOCK_DIR:h} writable?   ls -ld '${LOCK_DIR:h}'"; return 1; }
    # only ever take over a directory that is one of OUR locks (pid / who / branch / since, nothing else)
    extra=(${(f)"$(ls -A $LOCK_DIR 2>/dev/null | rg -v -x 'pid|who|branch|since')"})
    [[ -n ${extra[1]:-} ]] && { print -r -- "✗ $LOCK_DIR exists and is not an install lock (holds ${extra[1]}) — point ORACLE_APP_LOCK elsewhere:  export ORACLE_APP_LOCK=\${TMPDIR:-/tmp}/oracle-app-install.lock"; return 1; }
    ino=$(stat -f %i $LOCK_DIR 2>/dev/null)   # sampled BEFORE the staleness verdict, compared after the rename
    pid=$(cat $LOCK_DIR/pid 2>/dev/null); age=$(( $(date +%s) - $(stat -f %m $LOCK_DIR 2>/dev/null || date +%s) ))
    if [[ -z $pid ]] && (( age < 10 && waited < 15 )); then sleep 1; waited=$((waited + 1)); continue; fi   # being created right now
    if [[ -n $pid ]] && kill -0 $pid 2>/dev/null; then
      print -r -- "✗ install lock held by $(cat $LOCK_DIR/who 2>/dev/null) ($(cat $LOCK_DIR/branch 2>/dev/null)) since $(cat $LOCK_DIR/since 2>/dev/null), pid $pid"
      print -r -- "  wait for it:  while kill -0 $pid 2>/dev/null; do sleep 5; done; $retry"
      return 1
    fi
    # stale (its holder died without releasing it): rename it away — rename is atomic, so of two takers only one moves
    # it. Then make sure what we moved is the very lock we judged (same inode, same pid); if another taker replaced it
    # meanwhile, put it back — only into an empty spot, never inside a newer lock.
    grave=$LOCK_DIR.stale.$$
    if mv $LOCK_DIR $grave 2>/dev/null; then
      if [[ $(stat -f %i $grave 2>/dev/null) == $ino && $(cat $grave/pid 2>/dev/null) == $pid ]]; then
        print -r -- "! stale install lock from $(cat $grave/who 2>/dev/null) at $(cat $grave/since 2>/dev/null) (pid ${pid:-none} gone) — taking it over"
        rm -rf $grave
      elif [ ! -e $LOCK_DIR ]; then mv $grave $LOCK_DIR 2>/dev/null || rm -rf $grave
      else rm -rf $grave; fi
    fi
    tries=$((tries + 1))
    (( tries > 20 )) && { print -r -- "✗ cannot take over the stale install lock $LOCK_DIR (rename keeps failing):  ls -ld '$LOCK_DIR' '${LOCK_DIR:h}'"; return 1; }
    sleep 0.2
  done
  print -r -- $$ > $LOCK_DIR/pid; print -r -- $who > $LOCK_DIR/who; print -r -- $br > $LOCK_DIR/branch; date '+%H:%M:%S' > $LOCK_DIR/since
}
lock_drop() { [[ $(cat $LOCK_DIR/pid 2>/dev/null) == $$ ]] && rm -rf $LOCK_DIR; return 0 }
