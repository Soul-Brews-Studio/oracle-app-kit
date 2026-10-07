# install-lock.sh — sourced. One installer of /Applications/{ARRA Oracles,Neo,Pulse,Nexus,…}.app at a time.
# Two agents installing at once clobbered each other (2026-10-07). mkdir is atomic; the holder's pid, who,
# branch and start time are written inside; a holder whose pid is gone is a stale lock and is taken over.
#   lock_take  → 0 when held by us; 1 (with the holder named and the wait command) when someone else has it
#   lock_drop  → releases it. The CALLER sets `trap lock_drop EXIT INT TERM` right after lock_take: in zsh an
#                EXIT trap set inside a function fires when that function returns, which would drop the lock at once.
LOCK_DIR=${ORACLE_APP_LOCK:-${TMPDIR:-/tmp}/oracle-app-install.lock}
lock_take() {
  local who=${ORACLE_APP_WHO:-${HERDR_PANE_ID:-$USER}} br=$(git -C ${ZSH_ARGZERO:A:h}/.. branch --show-current 2>/dev/null)
  if ! mkdir $LOCK_DIR 2>/dev/null; then
    local pid=$(cat $LOCK_DIR/pid 2>/dev/null)
    if [[ -n $pid ]] && kill -0 $pid 2>/dev/null; then
      echo "✗ install lock held by $(cat $LOCK_DIR/who 2>/dev/null) ($(cat $LOCK_DIR/branch 2>/dev/null)) since $(cat $LOCK_DIR/since 2>/dev/null), pid $pid"
      echo "  wait for it:  while [ -d '$LOCK_DIR' ]; do sleep 5; done; $ZSH_ARGZERO $*"
      return 1
    fi
    echo "! stale install lock from $(cat $LOCK_DIR/who 2>/dev/null) at $(cat $LOCK_DIR/since 2>/dev/null) (pid ${pid:-?} gone) — taking it over"
    rm -rf $LOCK_DIR; mkdir $LOCK_DIR || return 1
  fi
  print -r -- $$ > $LOCK_DIR/pid; print -r -- $who > $LOCK_DIR/who; print -r -- $br > $LOCK_DIR/branch; date '+%H:%M:%S' > $LOCK_DIR/since
}
lock_drop() { [[ $(cat $LOCK_DIR/pid 2>/dev/null) == $$ ]] && rm -rf $LOCK_DIR; return 0 }
