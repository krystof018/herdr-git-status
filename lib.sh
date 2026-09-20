#!/usr/bin/env bash
# Shared helpers for the gitlab-ci-status herdr plugin. Source this file.

# Colors: empty when NO_COLOR set or stdout is not a tty.
if [ -z "${NO_COLOR:-}" ] && [ -t 1 ]; then
  GCI_RESET=$'\033[0m'; GCI_GREEN=$'\033[32m'; GCI_RED=$'\033[31m'
  GCI_YELLOW=$'\033[33m'; GCI_GRAY=$'\033[90m'; GCI_BLUE=$'\033[34m'; GCI_BOLD=$'\033[1m'
else
  GCI_RESET=''; GCI_GREEN=''; GCI_RED=''; GCI_YELLOW=''; GCI_GRAY=''; GCI_BLUE=''; GCI_BOLD=''
fi

# Always-required tools. The provider CLI (glab for GitLab, gh for GitHub) is
# checked per-repo in gci_latest_ci, since only one is needed for a given remote.
gci_require_deps() {
  local missing=()
  for bin in jq git; do command -v "$bin" >/dev/null 2>&1 || missing+=("$bin"); done
  if [ ${#missing[@]} -gt 0 ]; then
    printf 'Missing dependency: %s\n' "${missing[*]}" >&2
    printf 'Install: brew install %s\n' "${missing[*]}" >&2
    return 1
  fi
}

# Load KEY=VALUE lines from <dir>/.env without overriding vars already in the
# environment (so real env vars win). <dir> defaults to $HERDR_PLUGIN_CONFIG_DIR.
gci_load_env() {
  local dir="${1:-${HERDR_PLUGIN_CONFIG_DIR:-}}" f k v
  [ -n "$dir" ] && [ -f "$dir/.env" ] || return 0
  f="$dir/.env"
  while IFS='=' read -r k v; do
    case "$k" in ''|\#*) continue;; esac
    [ -z "${!k:-}" ] && export "$k=$v"
  done < "$f"
}

# Print "host<TAB>path" (path without trailing .git). Return 1 if not parseable.
gci_parse_remote() {
  local url="$1" host path rest
  case "$url" in
    ssh://*)
      rest="${url#ssh://}"; rest="${rest#*@}"
      host="${rest%%/*}"; host="${host%%:*}"
      path="${rest#*/}" ;;
    http://*|https://*)
      rest="${url#*://}"; rest="${rest#*@}"
      host="${rest%%/*}"
      path="${rest#*/}" ;;
    *@*:*)                       # scp-like: git@host:group/proj.git
      host="${url#*@}"; host="${host%%:*}"
      path="${url#*:}" ;;
    *) return 1 ;;
  esac
  path="${path%.git}"; path="${path%/}"
  [ -n "$host" ] && [ -n "$path" ] || return 1
  printf '%s\t%s\n' "$host" "$path"
}

gci_urlencode_path() { printf '%s\n' "${1//\//%2F}"; }

# Map a remote host to a CI provider: "gitlab", "github", or "" (unsupported).
gci_provider() {
  case "$1" in
    *gitlab*) printf 'gitlab' ;;
    *github*) printf 'github' ;;
    *)        printf '' ;;
  esac
}

# Provider-aware label for the detail pane's herdr border (overrides the plugin-id
# fallback "gitlab-ci-status"). Derived cheaply from origin — no API call — so it is
# safe to set at pane startup: "GitLab CI", "GitHub CI", or plain "CI" otherwise.
gci_pane_title() {
  local repo="$1" url parsed host
  url="$(git -C "$repo" remote get-url origin 2>/dev/null)" || { printf 'CI'; return; }
  parsed="$(gci_parse_remote "$url" 2>/dev/null)" || { printf 'CI'; return; }
  host="${parsed%%$'\t'*}"
  case "$(gci_provider "$host")" in
    gitlab) printf 'GitLab CI' ;;
    github) printf 'GitHub CI' ;;
    *)      printf 'CI' ;;
  esac
}

gci_status_glyph() {
  case "$1" in
    success)  printf '%s' "${GCI_GREEN}✓ passed${GCI_RESET}" ;;
    failed)   printf '%s' "${GCI_RED}✗ failed${GCI_RESET}" ;;
    running)  printf '%s' "${GCI_YELLOW}● running${GCI_RESET}" ;;
    pending|created|preparing|waiting_for_resource|scheduled)
              printf '%s' "${GCI_YELLOW}● $1${GCI_RESET}" ;;
    canceled|skipped)
              printf '%s' "${GCI_GRAY}• $1${GCI_RESET}" ;;
    manual)   printf '%s' "${GCI_BLUE}⚙ manual${GCI_RESET}" ;;
    *)        printf '%s' "${1:-unknown}" ;;
  esac
}

# Relative time from ISO-8601. Optional 2nd arg = reference epoch (for tests).
gci_relative_time() {
  local iso="$1" now="${2:-}" epoch base diff
  base="${iso%.*}"; base="${base%Z}"           # 2026-06-25T08:30:00
  epoch="$(date -u -d "$base" +%s 2>/dev/null \
        || date -u -j -f '%Y-%m-%dT%H:%M:%S' "$base" +%s 2>/dev/null)" \
        || { printf '%s\n' "$iso"; return; }
  [ -n "$now" ] || now="$(date -u +%s)"
  diff=$(( now - epoch )); [ "$diff" -lt 0 ] && diff=0
  if   [ "$diff" -lt 60 ];   then printf '%ds ago\n' "$diff"
  elif [ "$diff" -lt 3600 ]; then printf '%dm ago\n' "$(( diff / 60 ))"
  elif [ "$diff" -lt 86400 ];then printf '%dh ago\n' "$(( diff / 3600 ))"
  else printf '%dd ago\n' "$(( diff / 86400 ))"; fi
}

# CI status -> a single colored-dot emoji (for the spaces sidebar label).
gci_status_emoji() {
  case "$1" in
    success)  printf '🟢' ;;
    failed)   printf '🔴' ;;
    running|pending|created|preparing|waiting_for_resource|scheduled)
              printf '🟡' ;;
    *)        printf '⚪' ;;
  esac
}

# Normalize a GitHub Actions run (.status, .conclusion) to the canonical status
# vocabulary used by gci_status_glyph / gci_status_emoji.
gci_github_status() {
  # NB: avoid a local named `status` — it is a read-only special var in zsh.
  local st="$1" cc="$2"
  if [ "$st" != "completed" ]; then
    case "$st" in
      in_progress) printf 'running' ;;
      *)           printf 'pending' ;;   # queued / waiting / requested / pending
    esac
    return
  fi
  case "$cc" in
    success)                           printf 'success' ;;
    failure|timed_out|startup_failure) printf 'failed' ;;
    cancelled|canceled)                printf 'canceled' ;;
    skipped|stale)                     printf 'skipped' ;;
    action_required|neutral)           printf 'manual' ;;
    *)                                 printf 'unknown' ;;
  esac
}

# Canonical review state -> glyph (full vocabulary; used by the My-MRs pane and tests).
# States: conflict | changes | draft | approved | awaiting | merged | (anything else / "") -> "".
gci_review_glyph() {
  case "$1" in
    conflict) printf '⚠️' ;;
    changes)  printf '💬' ;;
    draft)    printf '📝' ;;
    approved) printf '✅' ;;
    awaiting) printf '👀' ;;
    merged)   printf '🔀' ;;
    *)        printf '' ;;
  esac
}

# Canonical review state -> the glyph SHOWN on a sidebar label under the "attention +
# ready" policy: only conflict, changes, and approved surface; draft/awaiting/none render
# as no glyph (plain !123 / #123).
gci_review_badge_glyph() {
  case "$1" in
    conflict) printf '⚠️' ;;
    changes)  printf '💬' ;;
    approved) printf '✅' ;;
    merged)   printf '🔀' ;;
    *)        printf '' ;;
  esac
}

# Canonical review state -> My-MRs pane section: "ready" (approved & mergeable),
# "action" (conflict or changes), or "" (not surfaced: draft/awaiting/none).
gci_mr_section() {
  case "$1" in
    approved)         printf 'ready' ;;
    conflict|changes) printf 'action' ;;
    *)                printf '' ;;
  esac
}

# GitLab MR -> canonical review state, from `detailed_merge_status` (GitLab 16.0+) with the
# MR's `blocking_discussions_resolved` flag as a fallback for statuses that don't themselves
# encode review. Returns: conflict | changes | draft | approved | awaiting.
# Args: <detailed_merge_status> [blocking_discussions_resolved: true|false]
gci_gitlab_review_state() {
  local dms="$1" blocking="${2:-true}"
  case "$dms" in
    conflict)                 printf 'conflict' ;;
    discussions_not_resolved) printf 'changes' ;;
    draft_status)             printf 'draft' ;;
    mergeable)                printf 'approved' ;;
    *)
      if [ "$blocking" = "false" ]; then printf 'changes'; else printf 'awaiting'; fi
      ;;
  esac
}

# GitHub PR -> canonical review state, from a GraphQL pull-request projection. Precedence
# matches the badge priority (conflict > changes > draft > approved > awaiting).
# Args: <isDraft: true|false> <mergeable: MERGEABLE|CONFLICTING|UNKNOWN>
#       <reviewDecision: APPROVED|CHANGES_REQUESTED|REVIEW_REQUIRED|''> <unresolved_threads: int>
gci_github_review_state() {
  local draft="$1" mergeable="$2" decision="$3" unresolved="${4:-0}"
  if [ "$mergeable" = "CONFLICTING" ]; then printf 'conflict'; return; fi
  if [ "$decision" = "CHANGES_REQUESTED" ] || { [ "${unresolved:-0}" -gt 0 ] 2>/dev/null; }; then
    printf 'changes'; return
  fi
  if [ "$draft" = "true" ]; then printf 'draft'; return; fi
  if [ "$decision" = "APPROVED" ] && [ "$mergeable" = "MERGEABLE" ]; then
    printf 'approved'; return
  fi
  printf 'awaiting'
}

# Remove the CI decoration the poller prepends to a label: a leading status emoji
# (with optional following space) and then an optional "!<digits> " (GitLab MR) or
# "#<digits> " (GitHub PR) token. Byte-safe (prefix removal), so it stays idempotent
# across re-applies and user renames. Both parts are optional, stripped independently.
gci_strip_ci_prefix() {
  local rest="$1" e body num after
  for e in '🟢' '🟡' '🔴' '⚪'; do
    if [ "${rest#"$e" }" != "$rest" ]; then rest="${rest#"$e" }"; break; fi
    if [ "${rest#"$e"}"  != "$rest" ]; then rest="${rest#"$e"}";  break; fi
  done
  # Optional review glyph glued to the MR sigil (e.g. "✅!123"). Only stripped when it is
  # immediately followed by a sigil+digit, so a user label that merely starts with one of
  # these emoji (e.g. "✅ done") is never clobbered.
  for e in '⚠️' '💬' '📝' '✅' '👀' '🔀'; do
    case "$rest" in
      "$e"'!'[0-9]*|"$e"'#'[0-9]*) rest="${rest#"$e"}"; break ;;
    esac
  done
  case "$rest" in
    '!'[0-9]*|'#'[0-9]*)
      body="${rest#?}"                  # drop the sigil (! or #)
      num="${body%%[![:digit:]]*}"      # leading run of digits
      after="${body#"$num"}"
      case "$after" in ' '*) rest="${after# }" ;; esac
      ;;
  esac
  printf '%s' "$rest"
}

# Ordered cwds (foreground_cwd, else cwd) of a workspace's panes, one per line, in list order.
gci_pane_cwds() {
  local wsid="$1" panes_json="$2"
  printf '%s' "$panes_json" | jq -r --arg w "$wsid" '
    (.result.panes // .panes // .)[] | select(.workspace_id == $w) | (.foreground_cwd // .cwd) // empty
  ' 2>/dev/null
}

# True (exit 0) when <dir> is a git work tree that has an origin remote — i.e. a real project
# checkout, as opposed to a remote-less git dir like the status-bar plugin's own repo.
gci_git_has_origin() {
  local dir="$1"
  [ -n "$dir" ] || return 1
  git -C "$dir" rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 1
  [ -n "$(git -C "$dir" remote get-url origin 2>/dev/null)" ]
}

# Choose the cwd that represents a workspace's repo from a `herdr pane list` JSON blob.
# Prefer the first pane whose cwd is a git repo WITH an origin remote (the real project
# checkout). This skips panes like the status bar, whose cwd is a remote-less git dir and
# would otherwise shadow the repo and drop the CI dot from every space that has a bar. Falls
# back to the first pane of the workspace when none qualifies.
# Args: <workspace_id> <pane_list_json>. Echoes the cwd, or nothing.
gci_pick_pane_cwd() {
  local wsid="$1" panes_json="$2" cwd first=""
  while IFS= read -r cwd; do
    [ -n "$cwd" ] || continue
    [ -n "$first" ] || first="$cwd"
    if gci_git_has_origin "$cwd"; then printf '%s\n' "$cwd"; return 0; fi
  done < <(gci_pane_cwds "$wsid" "$panes_json")
  [ -n "$first" ] && printf '%s\n' "$first"
}

# True (exit 0) only when <pidfile> exists and names a live process. Backs the poller's
# is_running check and its self-healing `start`, which relaunches whenever this is false.
gci_daemon_alive() {
  local pidfile="$1" pid
  [ -f "$pidfile" ] || return 1
  pid="$(cat "$pidfile" 2>/dev/null)"
  [ -n "$pid" ] || return 1
  kill -0 "$pid" 2>/dev/null
}

# Emit <text> as an OSC 8 terminal hyperlink to <url> (Ctrl/Cmd-clickable in modern
# terminals). Falls back to plain <text> when colors are disabled (NO_COLOR / not a
# tty), so output stays deterministic in tests and pipes.
gci_hyperlink() {
  local url="$1" text="$2"
  if [ -z "$GCI_RESET" ]; then printf '%s' "$text"; return; fi
  # BEL-terminated OSC 8 (more widely supported than the ESC-backslash ST form).
  printf '\033]8;;%s\a%s\033]8;;\a' "$url" "$text"
}

# Resolve a repo's latest CI state for its current branch, dispatching on the remote
# provider (GitLab pipelines via glab, GitHub Actions runs via gh). Returns everything
# via globals (NOT stdout) so it can be called without a subshell:
#   GCI_HOST, GCI_PATH, GCI_BRANCH, GCI_PROVIDER, GCI_ERR (on error),
#   GCI_STATUS  canonical status (success/failed/running/pending/canceled/skipped/
#               manual/unknown), or "" when the branch has no pipeline/run,
#   GCI_CI_ID, GCI_CI_URL, GCI_CI_UPDATED.
# Return codes:
#   0 ok | 1 not-a-git-repo | 2 no-origin | 3 remote-not-parseable
#   4 unsupported-host (not GitLab/GitHub) | 5 api-error (incl. missing provider CLI)
gci_latest_ci() {
  local repo="$1" url parsed enc resp run st cc
  GCI_HOST=""; GCI_PATH=""; GCI_BRANCH=""; GCI_PROVIDER=""; GCI_ERR=""
  GCI_STATUS=""; GCI_CI_ID=""; GCI_CI_URL=""; GCI_CI_UPDATED=""
  git -C "$repo" rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 1
  url="$(git -C "$repo" remote get-url origin 2>/dev/null)" || return 2
  parsed="$(gci_parse_remote "$url")" || return 3
  GCI_HOST="${parsed%%$'\t'*}"; GCI_PATH="${parsed#*$'\t'}"
  GCI_PROVIDER="$(gci_provider "$GCI_HOST")"
  [ -n "$GCI_PROVIDER" ] || return 4
  GCI_BRANCH="$(git -C "$repo" rev-parse --abbrev-ref HEAD 2>/dev/null)"

  if [ "$GCI_PROVIDER" = "gitlab" ]; then
    command -v glab >/dev/null 2>&1 || { GCI_ERR="glab not found — install it (brew install glab) and run: glab auth login"; return 5; }
    enc="$(gci_urlencode_path "$GCI_PATH")"
    resp="$(cd "$repo" && glab api "projects/$enc/pipelines?ref=$GCI_BRANCH&per_page=1" 2>&1)" || { GCI_ERR="$resp"; return 5; }
    run="$(printf '%s' "$resp" | jq -c '.[0] // empty' 2>/dev/null)"
    [ -n "$run" ] || return 0
    GCI_STATUS="$(printf '%s' "$run" | jq -r '.status // "unknown"')"
    GCI_CI_ID="$(printf '%s' "$run" | jq -r '.id // empty')"
    GCI_CI_URL="$(printf '%s' "$run" | jq -r '.web_url // empty')"
    GCI_CI_UPDATED="$(printf '%s' "$run" | jq -r '.updated_at // empty')"
  else
    command -v gh >/dev/null 2>&1 || { GCI_ERR="gh not found — install it (brew install gh) and run: gh auth login"; return 5; }
    resp="$(cd "$repo" && gh api "repos/$GCI_PATH/actions/runs?branch=$GCI_BRANCH&per_page=1" 2>&1)" || { GCI_ERR="$resp"; return 5; }
    run="$(printf '%s' "$resp" | jq -c '.workflow_runs[0] // empty' 2>/dev/null)"
    [ -n "$run" ] || return 0
    st="$(printf '%s' "$run" | jq -r '.status // "unknown"')"
    cc="$(printf '%s' "$run" | jq -r '.conclusion // empty')"
    GCI_STATUS="$(gci_github_status "$st" "$cc")"
    GCI_CI_ID="$(printf '%s' "$run" | jq -r '.id // empty')"
    GCI_CI_URL="$(printf '%s' "$run" | jq -r '.html_url // empty')"
    GCI_CI_UPDATED="$(printf '%s' "$run" | jq -r '.updated_at // empty')"
  fi
  return 0
}

# Look up the open MR/PR whose source/head branch is <branch>, dispatching on
# <provider> ("gitlab"|"github"). Sets globals (NOT stdout): GCI_MR_IID, GCI_MR_URL,
# and GCI_MR_SIGIL ("!" for GitLab, "#" for GitHub) — all "" on error/none. The args
# come from a prior gci_latest_ci call; <repo> supplies the CLI's host + auth context.
# Return: 0 found | 1 missing args | 2 api-error | 3 no open MR/PR.
gci_open_pr() {
  local repo="$1" path="$2" branch="$3" provider="$4" enc resp owner
  GCI_MR_IID=""; GCI_MR_URL=""; GCI_MR_SIGIL=""
  [ -n "$path" ] && [ -n "$branch" ] || return 1
  if [ "$provider" = "gitlab" ]; then
    GCI_MR_SIGIL="!"
    enc="$(gci_urlencode_path "$path")"
    resp="$(cd "$repo" && glab api "projects/$enc/merge_requests?source_branch=$branch&state=opened&per_page=1" 2>/dev/null)" || return 2
    GCI_MR_IID="$(printf '%s' "$resp" | jq -r '.[0].iid // empty' 2>/dev/null)"
    GCI_MR_URL="$(printf '%s' "$resp" | jq -r '.[0].web_url // empty' 2>/dev/null)"
  elif [ "$provider" = "github" ]; then
    GCI_MR_SIGIL="#"
    owner="${path%%/*}"
    resp="$(cd "$repo" && gh api "repos/$path/pulls?head=$owner:$branch&state=open&per_page=1" 2>/dev/null)" || return 2
    GCI_MR_IID="$(printf '%s' "$resp" | jq -r '.[0].number // empty' 2>/dev/null)"
    GCI_MR_URL="$(printf '%s' "$resp" | jq -r '.[0].html_url // empty' 2>/dev/null)"
  else
    return 1
  fi
  [ -n "$GCI_MR_IID" ] || { GCI_MR_IID=""; GCI_MR_URL=""; return 3; }
  return 0
}

# Look up the MERGED MR/PR whose source/head branch is <branch>, so a positive "merged" badge
# can replace the open-PR token once gci_open_pr reports none. Same shape as gci_open_pr: sets
# globals (NOT stdout) GCI_MR_IID, GCI_MR_URL, GCI_MR_SIGIL ("!" GitLab / "#" GitHub) — all ""
# on none/error — plus GCI_REVIEW="merged" on success. GitHub's state=closed returns closed
# OR merged PRs, so merged is gated on `.merged_at != null`; GitLab's state=merged is already
# merged-only. Return: 0 merged | 1 missing args | 2 api-error | 3 not merged.
gci_merged_pr() {
  local repo="$1" path="$2" branch="$3" provider="$4" enc resp owner
  GCI_MR_IID=""; GCI_MR_URL=""; GCI_MR_SIGIL=""; GCI_REVIEW=""
  [ -n "$path" ] && [ -n "$branch" ] || return 1
  if [ "$provider" = "gitlab" ]; then
    GCI_MR_SIGIL="!"
    enc="$(gci_urlencode_path "$path")"
    resp="$(cd "$repo" && glab api "projects/$enc/merge_requests?source_branch=$branch&state=merged&per_page=1" 2>/dev/null)" || return 2
    GCI_MR_IID="$(printf '%s' "$resp" | jq -r '.[0].iid // empty' 2>/dev/null)"
    GCI_MR_URL="$(printf '%s' "$resp" | jq -r '.[0].web_url // empty' 2>/dev/null)"
  elif [ "$provider" = "github" ]; then
    GCI_MR_SIGIL="#"
    owner="${path%%/*}"
    resp="$(cd "$repo" && gh api "repos/$path/pulls?head=$owner:$branch&state=closed&per_page=1" 2>/dev/null)" || return 2
    if [ -n "$(printf '%s' "$resp" | jq -r '.[0].merged_at // empty' 2>/dev/null)" ]; then
      GCI_MR_IID="$(printf '%s' "$resp" | jq -r '.[0].number // empty' 2>/dev/null)"
      GCI_MR_URL="$(printf '%s' "$resp" | jq -r '.[0].html_url // empty' 2>/dev/null)"
    fi
  else
    return 1
  fi
  [ -n "$GCI_MR_IID" ] || { GCI_MR_IID=""; GCI_MR_URL=""; return 3; }
  GCI_REVIEW="merged"
  return 0
}

# Resolve the canonical review state of a single open MR/PR. Network call; dispatches on
# <provider>. Sets GCI_REVIEW to conflict|changes|draft|approved|awaiting, or "" on any
# error/missing data (callers fall back to no glyph). <repo> supplies CLI auth/host context.
# For GitLab, <path> may be a urlencodable project path OR a numeric project id (both work
# with the projects/:id/merge_requests/:iid endpoint). For GitHub, <path> is "owner/name".
# Args: repo path iid provider
gci_review_for_mr() {
  local repo="$1" path="$2" iid="$3" provider="$4"
  local enc resp dms blocking draft mergeable decision unresolved owner name
  GCI_REVIEW=""
  [ -n "$path" ] && [ -n "$iid" ] || return 0
  if [ "$provider" = "gitlab" ]; then
    enc="$(gci_urlencode_path "$path")"
    resp="$(cd "$repo" && glab api "projects/$enc/merge_requests/$iid" 2>/dev/null)" || return 0
    dms="$(printf '%s' "$resp" | jq -r '.detailed_merge_status // empty' 2>/dev/null)"
    [ -n "$dms" ] || return 0
    blocking="$(printf '%s' "$resp" | jq -r '.blocking_discussions_resolved // true' 2>/dev/null)"
    GCI_REVIEW="$(gci_gitlab_review_state "$dms" "$blocking")"
  elif [ "$provider" = "github" ]; then
    owner="${path%%/*}"; name="${path#*/}"
    resp="$(cd "$repo" && gh api graphql -f owner="$owner" -f name="$name" -F number="$iid" -f query='
      query($owner:String!,$name:String!,$number:Int!){
        repository(owner:$owner,name:$name){
          pullRequest(number:$number){
            isDraft
            mergeable
            reviewDecision
            reviewThreads(first:100){ nodes { isResolved } }
          }
        }
      }' 2>/dev/null)" || return 0
    draft="$(printf '%s' "$resp" | jq -r '.data.repository.pullRequest.isDraft // empty' 2>/dev/null)"
    [ -n "$draft" ] || return 0
    mergeable="$(printf '%s' "$resp" | jq -r '.data.repository.pullRequest.mergeable // "UNKNOWN"' 2>/dev/null)"
    decision="$(printf '%s' "$resp" | jq -r '.data.repository.pullRequest.reviewDecision // ""' 2>/dev/null)"
    unresolved="$(printf '%s' "$resp" | jq -r '[.data.repository.pullRequest.reviewThreads.nodes[]? | select(.isResolved==false)] | length' 2>/dev/null)"
    GCI_REVIEW="$(gci_github_review_state "$draft" "$mergeable" "$decision" "${unresolved:-0}")"
  fi
  return 0
}

# List MY open MRs across all GitLab projects, classified by review state. Emits TSV rows:
#   state \t !<iid> \t web_url \t project_short \t updated_at
# <repo> supplies glab auth/host context (defaults to $PWD). No-op (prints nothing) if glab
# is missing or the current user can't be resolved.
gci_my_mrs_gitlab() {
  local repo="${1:-$PWD}" me resp pid iid url upd proj
  command -v glab >/dev/null 2>&1 || return 0
  me="$(cd "$repo" && glab api user 2>/dev/null | jq -r '.username // empty')"
  [ -n "$me" ] || return 0
  resp="$(cd "$repo" && glab api "merge_requests?author_username=$me&state=opened&scope=all&per_page=50" 2>/dev/null)" || return 0
  while IFS=$'\t' read -r pid iid url upd; do
    [ -n "$iid" ] || continue
    gci_review_for_mr "$repo" "$pid" "$iid" "gitlab"
    proj="${url#https://}"; proj="${proj#*/}"; proj="${proj%%/-/*}"; proj="${proj##*/}"
    printf '%s\t!%s\t%s\t%s\t%s\n' "$GCI_REVIEW" "$iid" "$url" "$proj" "$upd"
  done < <(printf '%s' "$resp" | jq -r '.[] | [(.project_id|tostring), (.iid|tostring), .web_url, (.updated_at // .created_at)] | @tsv' 2>/dev/null)
}

# List MY open PRs across all GitHub repos, classified by review state. Emits TSV rows:
#   state \t #<num> \t html_url \t repo_name \t updated_at
# <repo> supplies gh auth/host context (defaults to $PWD). No-op if gh is missing.
gci_my_mrs_github() {
  local repo="${1:-$PWD}" resp owner name num url upd
  command -v gh >/dev/null 2>&1 || return 0
  resp="$(cd "$repo" && gh search prs --author=@me --state=open --limit 50 --json number,url,repository,updatedAt 2>/dev/null)" || return 0
  while IFS=$'\t' read -r owner name num url upd; do
    [ -n "$num" ] || continue
    gci_review_for_mr "$repo" "$owner/$name" "$num" "github"
    printf '%s\t#%s\t%s\t%s\t%s\n' "$GCI_REVIEW" "$num" "$url" "$name" "$upd"
  done < <(printf '%s' "$resp" | jq -r '.[] | [(.repository.nameWithOwner|split("/")[0]), (.repository.nameWithOwner|split("/")[1]), (.number|tostring), .url, .updatedAt] | @tsv' 2>/dev/null)
}

# Stream recent FAILED pipelines/runs for <branch> (newest first), up to <limit> lines of
#   <id>\t<web_url>\t<updated_at>
# Args: repo path branch provider [limit]. <repo> supplies the CLI's host + auth context.
# Empty output = no failures, or a transient API/CLI error (treated as "none" — hard errors
# are already surfaced by gci_latest_ci, which build_frame checks before calling this).
gci_failed_ci() {
  local repo="$1" path="$2" branch="$3" provider="$4" limit="${5:-5}" enc
  [ -n "$path" ] && [ -n "$branch" ] || return 0
  if [ "$provider" = "gitlab" ]; then
    enc="$(gci_urlencode_path "$path")"
    (cd "$repo" && glab api "projects/$enc/pipelines?ref=$branch&status=failed&per_page=$limit" 2>/dev/null) \
      | jq -r '.[] | "\(.id)\t\(.web_url)\t\(.updated_at // .created_at)"' 2>/dev/null
  elif [ "$provider" = "github" ]; then
    (cd "$repo" && gh api "repos/$path/actions/runs?branch=$branch&status=failure&per_page=$limit" 2>/dev/null) \
      | jq -r '.workflow_runs[] | "\(.id)\t\(.html_url)\t\(.updated_at // .created_at)"' 2>/dev/null
  fi
}
