#!/usr/bin/env bash
# Always-live poller: reflects each space's GitLab CI status as a colored dot
# prefixed onto the space's label in the herdr sidebar. It never touches the
# agent status dot. Control: start | stop | toggle | status | poll-once | restore | run
#
# Env:
#   GITLAB_CI_REFRESH   poll interval seconds (default 30)
#   GITLAB_CI_DRYRUN    if set, print intended renames instead of applying them
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$DIR/lib.sh"
gci_load_env "${HERDR_PLUGIN_CONFIG_DIR:-$DIR}"

HERDR="${HERDR_BIN_PATH:-herdr}"
STATE_DIR="${HERDR_PLUGIN_STATE_DIR:-$DIR/.state}"
PIDFILE="$STATE_DIR/poller.pid"
LOGFILE="$STATE_DIR/poller.log"
INTERVAL="${GITLAB_CI_REFRESH:-30}"
DRYRUN="${GITLAB_CI_DRYRUN:-}"
START_HEAL_SECS="${GITLAB_CI_START_HEAL_SECS:-5}"   # `start` watches this long, relaunching if the daemon dies
mkdir -p "$STATE_DIR" 2>/dev/null || true

# -> lines "workspace_id<TAB>label"
ws_list() {
  "$HERDR" workspace list 2>/dev/null \
    | jq -r '(.result.workspaces // .workspaces // .)[] | "\(.workspace_id)\t\(.label)"'
}

# Resolve a repo's sidebar decoration into globals (NOT stdout) so it can run
# without a subshell — that lets the MR/PR lookup reuse the path/branch/provider
# that gci_latest_ci just resolved:
#   SPACE_EMOJI  status emoji, "" (unsupported remote), or "SKIP" (transient error)
#   SPACE_MR     open MR/PR token incl. sigil ("!123" / "#123") or "" (none)
status_for_repo() {
  local cwd="$1" rc glyph
  SPACE_EMOJI=""; SPACE_MR=""
  gci_latest_ci "$cwd"; rc=$?
  case $rc in
    1|2|3|4) return ;;
    5)       SPACE_EMOJI="SKIP"; return ;;
    0)
      if [ -n "$GCI_STATUS" ]; then
        SPACE_EMOJI="$(gci_status_emoji "$GCI_STATUS")"
      else
        SPACE_EMOJI="$(gci_status_emoji '')"   # supported remote, but no pipeline/run for this branch
      fi
      if gci_open_pr "$cwd" "$GCI_PATH" "$GCI_BRANCH" "$GCI_PROVIDER"; then
        gci_review_for_mr "$cwd" "$GCI_PATH" "$GCI_MR_IID" "$GCI_PROVIDER"
        glyph="$(gci_review_badge_glyph "$GCI_REVIEW")"
        SPACE_MR="$glyph$GCI_MR_SIGIL$GCI_MR_IID"
      fi
      ;;
  esac
}

# Drive the loop on fd 9, NOT stdin: inner commands (herdr/glab/git) inherit stdin, and
# if the loop fed them via stdin they would consume it and truncate the loop after the
# first space. The pane list is fetched once per poll and reused for all spaces.
poll_once() {
  local panes wsid label base cwd new
  panes="$("$HERDR" pane list 2>/dev/null)"
  while IFS=$'\t' read -r wsid label <&9; do
    [ -n "$wsid" ] || continue
    base="$(gci_strip_ci_prefix "$label")"
    # Resolve the space's repo from a real terminal pane, skipping plugin panes (e.g. the
    # status-bar pane, which sits on top of the layout but lives in a remote-less plugin dir).
    cwd="$(gci_pick_pane_cwd "$wsid" "$panes")"
    if [ -z "$cwd" ]; then SPACE_EMOJI=""; SPACE_MR=""; else status_for_repo "$cwd"; fi
    [ "$SPACE_EMOJI" = "SKIP" ] && continue
    new="$base"
    [ -n "$SPACE_MR" ] && new="$SPACE_MR $new"            # "!123 dbt" / "#123 dbt"
    [ -n "$SPACE_EMOJI" ] && new="$SPACE_EMOJI $new"      # "🟢 #123 dbt"
    [ "$new" = "$label" ] && continue
    if [ -n "$DRYRUN" ]; then
      printf 'would rename %s: %q -> %q\n' "$wsid" "$label" "$new"
    else
      "$HERDR" workspace rename "$wsid" "$new" >/dev/null 2>&1
    fi
  done 9< <(ws_list)
}

restore_labels() {
  local wsid label base
  while IFS=$'\t' read -r wsid label <&9; do
    [ -n "$wsid" ] || continue
    base="$(gci_strip_ci_prefix "$label")"
    [ "$base" = "$label" ] && continue
    if [ -n "$DRYRUN" ]; then
      printf 'would restore %s: %q -> %q\n' "$wsid" "$label" "$base"
    else
      "$HERDR" workspace rename "$wsid" "$base" >/dev/null 2>&1
    fi
  done 9< <(ws_list)
}

is_running() { gci_daemon_alive "$PIDFILE"; }

# Launch a detached daemon and record its pid. The run-loop takes pidfile ownership, so an
# older daemon (if any) self-exits on its next tick — this converges to a single poller.
spawn_daemon() {
  nohup bash "$DIR/poller-ctl.sh" run >>"$LOGFILE" 2>&1 </dev/null &
  echo $! > "$PIDFILE"
  disown 2>/dev/null || true
}

case "${1:-status}" in
  run)
    echo $$ > "$PIDFILE"
    trap 'exit 0' TERM INT
    # Loop only while we remain the registered owner: `stop` removes the pidfile and
    # a newer `start` overwrites it, so any stale/duplicate daemon self-exits.
    while [ "$(cat "$PIDFILE" 2>/dev/null)" = "$$" ]; do
      poll_once
      sleep "$INTERVAL"
    done
    ;;
  start)
    # Self-healing: guarantee a live daemon by the time we return. Launch when none is
    # running, then keep watching for START_HEAL_SECS and relaunch if the daemon vanishes —
    # e.g. a one-shot `stop` racing this `start` killed it, or it died on startup. Without
    # this, a rapid stop/start could silently leave the poller stopped. A `stop` genuinely
    # issued after the window still wins (it removes the pidfile and the daemon self-exits).
    deadline=$(( SECONDS + START_HEAL_SECS ))
    while :; do
      is_running || spawn_daemon
      [ "$SECONDS" -ge "$deadline" ] && break
      sleep 1
    done
    if is_running; then echo "poller running (pid $(cat "$PIDFILE")), interval ${INTERVAL}s"
    else echo "poller failed to start" >&2; exit 1; fi
    ;;
  stop)
    if [ -f "$PIDFILE" ]; then
      p="$(cat "$PIDFILE" 2>/dev/null)"; rm -f "$PIDFILE"
      if [ -n "$p" ]; then
        kill "$p" 2>/dev/null
        # Bounded wait for graceful exit (the herdr call paces each iteration); TERM is
        # deferred while bash is mid-glab, so force-kill if it's still alive afterward.
        for _ in $(seq 1 40); do kill -0 "$p" 2>/dev/null || break; "$HERDR" workspace list >/dev/null 2>&1; done
        kill -0 "$p" 2>/dev/null && kill -9 "$p" 2>/dev/null
      fi
    fi
    restore_labels
    echo "poller stopped; labels restored"
    ;;
  toggle)
    if is_running; then exec bash "$DIR/poller-ctl.sh" stop; else exec bash "$DIR/poller-ctl.sh" start; fi
    ;;
  status)
    if is_running; then echo "running (pid $(cat "$PIDFILE"))"; else echo "stopped"; fi
    ;;
  poll-once) poll_once ;;
  restore)   restore_labels ;;
  *) echo "usage: poller-ctl.sh start|stop|toggle|status|poll-once|restore" >&2; exit 2 ;;
esac
