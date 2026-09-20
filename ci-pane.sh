#!/usr/bin/env bash
# Pane: live GitLab project link + CI pipeline status for the current branch.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$DIR/lib.sh"

# Optional config from $HERDR_PLUGIN_CONFIG_DIR/.env (only sets vars not already in env).
gci_load_env "${HERDR_PLUGIN_CONFIG_DIR:-$DIR}"

REPO="${GITLAB_CI_REPO:-$PWD}"
INTERVAL="${GITLAB_CI_REFRESH:-15}"
ONCE="${GITLAB_CI_ONCE:-}"

cleanup() { tput cnorm 2>/dev/null || true; }
trap cleanup EXIT INT TERM

render() {
  local out
  out="$(build_frame 2>&1)"
  clear 2>/dev/null || printf '\033[2J\033[H'
  printf '%s\n' "$out"
}

build_frame() {
  gci_require_deps || { printf '%s\n' "Install jq and git to use this plugin."; return 1; }

  local rc l
  gci_latest_ci "$REPO"; rc=$?
  l="CI"; [ "$GCI_PROVIDER" = gitlab ] && l="GitLab CI"; [ "$GCI_PROVIDER" = github ] && l="GitHub CI"
  case $rc in
    1) printf '%s CI%s\n\n  Not a git repository:\n  %s\n' "$GCI_BOLD" "$GCI_RESET" "$REPO"; return 1 ;;
    2) printf '%s CI%s\n\n  No "origin" remote in %s\n' "$GCI_BOLD" "$GCI_RESET" "$REPO"; return 1 ;;
    3) printf '%s CI%s\n\n  origin is not a parseable remote.\n' "$GCI_BOLD" "$GCI_RESET"; return 1 ;;
    4) printf '%s CI%s\n\n  origin is not a GitLab or GitHub remote (host: %s)\n' "$GCI_BOLD" "$GCI_RESET" "$GCI_HOST"; return 1 ;;
    5) printf '%s %s · %s%s\n\n  Branch    %s\n\n  %sError querying CI:%s\n  %s\n' \
         "$GCI_BOLD" "$l" "$GCI_HOST/$GCI_PATH" "$GCI_RESET" "$GCI_BRANCH" "$GCI_RED" "$GCI_RESET" "$GCI_ERR"; return 1 ;;
  esac

  # The project path, run/pipeline #id, and MR/PR number are OSC 8 hyperlinks (clickable
  # in a real terminal). We intentionally do NOT print the raw URLs — they read poorly and
  # the clickable text already carries the link.
  local ci_word pr_word proj_url rel ci_tok
  if [ "$GCI_PROVIDER" = "github" ]; then ci_word="Run"; pr_word="PR"; else ci_word="Pipeline"; pr_word="MR"; fi
  proj_url="https://$GCI_HOST/$GCI_PATH"
  printf '%s %s · %s%s\n\n' "$GCI_BOLD" "$l" "$GCI_HOST/$GCI_PATH" "$GCI_RESET"
  printf '  Project   %s\n' "$(gci_hyperlink "$proj_url" "$GCI_PATH")"
  printf '  Branch    %s\n\n' "$GCI_BRANCH"

  if [ -z "$GCI_STATUS" ]; then
    printf '  %-8s  %sNone for %s%s\n' "$ci_word" "$GCI_GRAY" "$GCI_BRANCH" "$GCI_RESET"
  else
    [ -n "$GCI_CI_UPDATED" ] && rel="$(gci_relative_time "$GCI_CI_UPDATED")" || rel=""
    ci_tok="#${GCI_CI_ID:-?}"
    [ -n "$GCI_CI_URL" ] && ci_tok="$(gci_hyperlink "$GCI_CI_URL" "$ci_tok")"
    printf '  %-8s  %s   %s\n' "$ci_word" "$ci_tok" "$(gci_status_glyph "$GCI_STATUS")"
    [ -n "$rel" ] && printf '  Updated   %s\n' "$rel"
  fi

  # Open MR/PR for this branch (the !123 / #123 is a clickable hyperlink).
  if gci_open_pr "$REPO" "$GCI_PATH" "$GCI_BRANCH" "$GCI_PROVIDER"; then
    printf '  %-8s  %s%s%s\n' \
      "$pr_word" "$GCI_BOLD" "$(gci_hyperlink "$GCI_MR_URL" "$GCI_MR_SIGIL$GCI_MR_IID")" "$GCI_RESET"
  fi

  # Recent failed pipelines/runs for this branch (newest first, each #id a clickable link).
  # The current latest run is already shown above, so skip it; fetch one extra so the list
  # still fills to the cap when the latest happens to be a failure too.
  local fail_max=5 f_id f_url f_upd shown=0
  while IFS=$'\t' read -r f_id f_url f_upd; do
    [ -n "$f_id" ] && [ "$f_id" != "$GCI_CI_ID" ] || continue
    [ "$shown" -eq 0 ] && printf '\n  %sRecent failures%s\n' "$GCI_BOLD" "$GCI_RESET"
    printf '    %s   %s✗%s %s\n' \
      "$(gci_hyperlink "$f_url" "#$f_id")" "$GCI_RED" "$GCI_RESET" "$(gci_relative_time "$f_upd")"
    shown=$((shown + 1))
    [ "$shown" -ge "$fail_max" ] && break
  done < <(gci_failed_ci "$REPO" "$GCI_CI_PATH" "$GCI_BRANCH" "$GCI_PROVIDER" $((fail_max + 1)))

  printf '\n  %sr%s refresh · %sq%s quit · auto-refresh %ss\n' \
    "$GCI_BOLD" "$GCI_RESET" "$GCI_BOLD" "$GCI_RESET" "$INTERVAL"
}

if [ -n "$ONCE" ]; then build_frame; exit 0; fi

# Name the herdr pane after the detected remote (e.g. "GitHub CI"), overriding herdr's
# plugin-id fallback ("gitlab-ci-status"). HERDR_PANE_ID is set by herdr for plugin panes.
if [ -n "${HERDR_PANE_ID:-}" ]; then
  "${HERDR_BIN_PATH:-herdr}" pane rename "$HERDR_PANE_ID" "$(gci_pane_title "$REPO")" >/dev/null 2>&1 || true
fi

tput civis 2>/dev/null || true
while true; do
  render
  if read -rsn1 -t "$INTERVAL" key 2>/dev/null; then
    case "$key" in q|Q) break;; r|R) :;; esac
  fi
done
