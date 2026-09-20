#!/usr/bin/env bash
set -u
export NO_COLOR=1                      # deterministic: no ANSI in assertions
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$DIR/lib.sh"

fail=0
check() { # check <label> <expected> <actual>
  if [ "$2" = "$3" ]; then printf 'ok   %s\n' "$1"
  else printf 'FAIL %s\n  expected: %q\n  actual:   %q\n' "$1" "$2" "$3"; fail=1; fi
}

# gci_parse_remote — all URL shapes -> "host<TAB>path"
check "ssh-scp"     "gitlab.com	myteam/my-service" "$(gci_parse_remote 'git@gitlab.com:myteam/my-service.git')"
check "ssh-url"     "gitlab.com	myteam/my-service" "$(gci_parse_remote 'ssh://git@gitlab.com/myteam/my-service.git')"
check "https"       "gitlab.com	myteam/my-service" "$(gci_parse_remote 'https://gitlab.com/myteam/my-service.git')"
check "https-token" "gitlab.com	myteam/my-service" "$(gci_parse_remote 'https://oauth2:tok@gitlab.com/myteam/my-service.git')"
check "subgroup"    "gitlab.com	grp/sub/proj"      "$(gci_parse_remote 'git@gitlab.com:grp/sub/proj.git')"
check "no-suffix"   "gitlab.com	myteam/my-service" "$(gci_parse_remote 'https://gitlab.com/myteam/my-service')"
gci_parse_remote 'not a url' >/dev/null 2>&1; check "bad-url-returns-1" "1" "$?"

# gci_urlencode_path
check "encode"      "grp%2Fsub%2Fproj" "$(gci_urlencode_path 'grp/sub/proj')"

# gci_status_glyph (NO_COLOR -> plain text)
check "st-success"  "✓ passed"  "$(gci_status_glyph success)"
check "st-failed"   "✗ failed"  "$(gci_status_glyph failed)"
check "st-running"  "● running" "$(gci_status_glyph running)"
check "st-manual"   "⚙ manual"  "$(gci_status_glyph manual)"
check "st-unknown"  "weird"     "$(gci_status_glyph weird)"

# gci_relative_time with fixed now (ref = 2026-06-25T08:30:00 + 120s)
ref_epoch="$(date -u -j -f '%Y-%m-%dT%H:%M:%S' '2026-06-25T08:32:00' +%s 2>/dev/null || date -u -d '2026-06-25T08:32:00' +%s)"
check "rel-2m"      "2m ago"    "$(gci_relative_time '2026-06-25T08:30:00.000Z' "$ref_epoch")"

# gci_status_emoji
check "em-success"  "🟢" "$(gci_status_emoji success)"
check "em-failed"   "🔴" "$(gci_status_emoji failed)"
check "em-running"  "🟡" "$(gci_status_emoji running)"
check "em-pending"  "🟡" "$(gci_status_emoji pending)"
check "em-other"    "⚪" "$(gci_status_emoji canceled)"

# gci_strip_ci_prefix (idempotent label cleanup)
check "strip-green"   "dbt"               "$(gci_strip_ci_prefix '🟢 dbt')"
check "strip-red"     "GQL review"        "$(gci_strip_ci_prefix '🔴 GQL review')"
check "strip-white"   "bakku-daemon"      "$(gci_strip_ci_prefix '⚪ bakku-daemon')"
check "strip-none"    "herdr"             "$(gci_strip_ci_prefix 'herdr')"
check "strip-nospace" "x"                 "$(gci_strip_ci_prefix '🟡x')"
check "strip-emoji-in-name" "my 🟢 repo"  "$(gci_strip_ci_prefix 'my 🟢 repo')"

# gci_strip_ci_prefix with the !<iid> merge-request token
check "strip-emoji-mr"   "dbt"          "$(gci_strip_ci_prefix '🟢 !123 dbt')"
check "strip-emoji-mr2"  "GQL review"   "$(gci_strip_ci_prefix '🔴 !7 GQL review')"
check "strip-mr-only"    "standalone"   "$(gci_strip_ci_prefix '!42 standalone')"
check "strip-mr-notnum"  "!abc foo"     "$(gci_strip_ci_prefix '!abc foo')"
check "strip-mr-bang"    "!important"   "$(gci_strip_ci_prefix '!important')"

# gci_hyperlink — NO_COLOR/non-tty falls back to plain text (no escape sequences)
check "hyperlink-plain"  "!123"         "$(gci_hyperlink 'https://gitlab.com/x/-/merge_requests/123' '!123')"

# gci_provider — host -> provider
check "prov-gitlab"  "gitlab" "$(gci_provider gitlab.com)"
check "prov-github"  "github" "$(gci_provider github.com)"
check "prov-gh-ent"  "github" "$(gci_provider github.acme.com)"
check "prov-self-gl" "gitlab" "$(gci_provider gitlab.example.org)"
check "prov-none"    ""       "$(gci_provider bitbucket.org)"

# gci_github_status — (status, conclusion) -> canonical status
check "gh-success"   "success"  "$(gci_github_status completed success)"
check "gh-failure"   "failed"   "$(gci_github_status completed failure)"
check "gh-timeout"   "failed"   "$(gci_github_status completed timed_out)"
check "gh-running"   "running"  "$(gci_github_status in_progress '')"
check "gh-queued"    "pending"  "$(gci_github_status queued '')"
check "gh-cancelled" "canceled" "$(gci_github_status completed cancelled)"
check "gh-skipped"   "skipped"  "$(gci_github_status completed skipped)"
check "gh-neutral"   "manual"   "$(gci_github_status completed neutral)"

# gci_strip_ci_prefix with the #<num> PR token (GitHub)
check "strip-emoji-pr"  "web app"  "$(gci_strip_ci_prefix '🟢 #42 web app')"
check "strip-pr-only"   "api"      "$(gci_strip_ci_prefix '#7 api')"
check "strip-pr-notnum" "#tag x"   "$(gci_strip_ci_prefix '#tag x')"

# gci_pane_title — provider-aware herdr pane label, derived from origin (no API call)
ptdir="$(mktemp -d)"
git -C "$ptdir" init -q 2>/dev/null
git -C "$ptdir" remote add origin 'git@github.com:acme/web-app.git' 2>/dev/null
check "title-github" "GitHub CI" "$(gci_pane_title "$ptdir")"
git -C "$ptdir" remote set-url origin 'https://gitlab.com/myteam/dbt.git' 2>/dev/null
check "title-gitlab" "GitLab CI" "$(gci_pane_title "$ptdir")"
git -C "$ptdir" remote set-url origin 'https://bitbucket.org/x/y.git' 2>/dev/null
check "title-other"  "CI"        "$(gci_pane_title "$ptdir")"
check "title-norepo" "CI"        "$(gci_pane_title "$ptdir/nonexistent")"
rm -rf "$ptdir"

# gci_review_glyph — full canonical vocabulary -> emoji
check "rg-conflict" "⚠️" "$(gci_review_glyph conflict)"
check "rg-changes"  "💬" "$(gci_review_glyph changes)"
check "rg-draft"    "📝" "$(gci_review_glyph draft)"
check "rg-approved" "✅" "$(gci_review_glyph approved)"
check "rg-awaiting" "👀" "$(gci_review_glyph awaiting)"
check "rg-none"     ""   "$(gci_review_glyph none)"
check "rg-empty"    ""   "$(gci_review_glyph '')"

# gci_review_badge_glyph — only attention + ready surface on the label
check "rb-conflict" "⚠️" "$(gci_review_badge_glyph conflict)"
check "rb-changes"  "💬" "$(gci_review_badge_glyph changes)"
check "rb-approved" "✅" "$(gci_review_badge_glyph approved)"
check "rb-draft"    ""   "$(gci_review_badge_glyph draft)"
check "rb-awaiting" ""   "$(gci_review_badge_glyph awaiting)"
check "rb-none"     ""   "$(gci_review_badge_glyph none)"

# gci_mr_section — My-MRs pane bucketing
check "sec-approved" "ready"  "$(gci_mr_section approved)"
check "sec-conflict" "action" "$(gci_mr_section conflict)"
check "sec-changes"  "action" "$(gci_mr_section changes)"
check "sec-draft"    ""       "$(gci_mr_section draft)"
check "sec-awaiting" ""       "$(gci_mr_section awaiting)"

# gci_gitlab_review_state — detailed_merge_status [+ blocking_discussions_resolved] -> canonical
check "gl-conflict"   "conflict" "$(gci_gitlab_review_state conflict)"
check "gl-discuss"    "changes"  "$(gci_gitlab_review_state discussions_not_resolved)"
check "gl-draft"      "draft"    "$(gci_gitlab_review_state draft_status)"
check "gl-mergeable"  "approved" "$(gci_gitlab_review_state mergeable)"
check "gl-notapprv"   "awaiting" "$(gci_gitlab_review_state not_approved)"
check "gl-cimust"     "awaiting" "$(gci_gitlab_review_state ci_must_pass)"
check "gl-unblocked"  "changes"  "$(gci_gitlab_review_state ci_still_running false)"
check "gl-blocked-ok" "awaiting" "$(gci_gitlab_review_state ci_still_running true)"

# gci_github_review_state — (isDraft, mergeable, reviewDecision, unresolved) -> canonical
check "gh-conflict"      "conflict" "$(gci_github_review_state false CONFLICTING APPROVED 0)"
check "gh-changes-dec"   "changes"  "$(gci_github_review_state false MERGEABLE CHANGES_REQUESTED 0)"
check "gh-changes-thr"   "changes"  "$(gci_github_review_state false MERGEABLE REVIEW_REQUIRED 2)"
check "gh-draft"         "draft"    "$(gci_github_review_state true MERGEABLE REVIEW_REQUIRED 0)"
check "gh-approved"      "approved" "$(gci_github_review_state false MERGEABLE APPROVED 0)"
check "gh-awaiting"      "awaiting" "$(gci_github_review_state false MERGEABLE REVIEW_REQUIRED 0)"
check "gh-unknown"       "awaiting" "$(gci_github_review_state false UNKNOWN '' 0)"
check "gh-conflict-wins" "conflict" "$(gci_github_review_state true CONFLICTING CHANGES_REQUESTED 3)"

# gci_strip_ci_prefix with a review glyph on the MR token (review-state badge)
check "strip-rev-ready"    "inventory"   "$(gci_strip_ci_prefix '🟢 ✅!250 inventory')"
check "strip-rev-changes"  "billing-api" "$(gci_strip_ci_prefix '🔴 💬!88 billing-api')"
check "strip-rev-conflict" "payments"    "$(gci_strip_ci_prefix '🔴 ⚠️!300 payments')"
check "strip-rev-pr"       "web-app"     "$(gci_strip_ci_prefix '🟢 ✅#41 web-app')"
check "strip-rev-noemoji"  "svc"         "$(gci_strip_ci_prefix '✅!7 svc')"
# A user label that merely starts with one of the glyphs (no MR sigil) is preserved:
check "strip-rev-keep"     "✅ done"      "$(gci_strip_ci_prefix '✅ done')"
# Idempotent: re-stripping an already-clean label is a no-op:
check "strip-rev-idem"     "inventory"   "$(gci_strip_ci_prefix "$(gci_strip_ci_prefix '🟢 ✅!250 inventory')")"

# gci_pane_cwds — ordered cwds of a workspace's panes (pure; foreground_cwd, else cwd).
panes_ord='{"result":{"panes":[
  {"workspace_id":"wA","foreground_cwd":"/a","cwd":"/A"},
  {"workspace_id":"wA","cwd":"/b"},
  {"workspace_id":"wX","cwd":"/x"}
]}}'
check "pane-cwds-order" "/a,/b" "$(gci_pane_cwds wA "$panes_ord" | paste -sd, -)"
check "pane-cwds-other" "/x"    "$(gci_pane_cwds wX "$panes_ord")"
check "pane-cwds-none"  ""      "$(gci_pane_cwds wZ "$panes_ord")"

# gci_git_has_origin — true only for a git work tree that has an origin remote.
ght="$(mktemp -d)"
git -C "$ght" init -q                                             # git, no origin
gci_git_has_origin "$ght";      check "origin-none"    "1" "$?"
git -C "$ght" remote add origin git@gitlab.com:me/proj.git
gci_git_has_origin "$ght";      check "origin-yes"     "0" "$?"   # git + origin
gci_git_has_origin "$ght/nope"; check "origin-nonrepo" "1" "$?"
gci_git_has_origin "";          check "origin-empty"   "1" "$?"
rm -rf "$ght"

# gci_pick_pane_cwd — prefer the first pane that is a git repo WITH an origin remote, so a
# remote-less git dir (e.g. the status-bar plugin's own repo) never shadows the real repo.
pt="$(mktemp -d)"; mkdir -p "$pt/plug" "$pt/repo" "$pt/plain"
git -C "$pt/plug" init -q                                         # git, NO origin (like the bar)
git -C "$pt/repo" init -q; git -C "$pt/repo" remote add origin git@github.com:me/app.git
pick_json='{"result":{"panes":[
  {"workspace_id":"wA","label":"status-bar","foreground_cwd":"'"$pt/plug"'"},
  {"workspace_id":"wA","cwd":"'"$pt/plain"'"},
  {"workspace_id":"wA","foreground_cwd":"'"$pt/repo"'"}
]}}'
# The status-bar (remote-less git) and non-git panes are skipped; the repo-with-origin wins:
check "cwd-git-remote"   "$pt/repo" "$(gci_pick_pane_cwd wA "$pick_json")"
# No pane has a remote -> fall back to the first pane's cwd:
pick_none='{"panes":[{"workspace_id":"wB","cwd":"'"$pt/plug"'"},{"workspace_id":"wB","cwd":"'"$pt/plain"'"}]}'
check "cwd-git-fallback" "$pt/plug" "$(gci_pick_pane_cwd wB "$pick_none")"
# Unknown workspace -> empty:
check "cwd-git-none"     ""         "$(gci_pick_pane_cwd wZ "$pick_json")"
rm -rf "$pt"

# gci_upstream_path — fork checkouts: `upstream` remote on the SAME host as origin -> its
# slug (used to retry PR/MR + CI lookups in the base repo); anything else -> empty.
ut="$(mktemp -d)"
git -C "$ut" init -q
check "up-no-origin"   ""         "$(gci_upstream_path "$ut")"
git -C "$ut" remote add origin git@github.com:me/app.git
check "up-no-upstream" ""         "$(gci_upstream_path "$ut")"
git -C "$ut" remote add upstream git@github.com:core/app.git
check "up-same-host"   "core/app" "$(gci_upstream_path "$ut")"
git -C "$ut" remote set-url upstream https://github.com/core/app
check "up-https-form"  "core/app" "$(gci_upstream_path "$ut")"
git -C "$ut" remote set-url upstream git@gitlab.com:core/app.git
check "up-other-host"  ""         "$(gci_upstream_path "$ut")"
check "up-nonrepo"     ""         "$(gci_upstream_path "$ut/nope")"
rm -rf "$ut"

# gci_daemon_alive — true only when <pidfile> exists and names a live process. Backs the
# poller's is_running check and its self-healing `start` (which relaunches when this is false).
dtmp="$(mktemp)"
echo $$ > "$dtmp"                                   # our own pid -> alive
gci_daemon_alive "$dtmp"; check "daemon-alive-self" "0" "$?"
( exit 0 ) & deadpid=$!; wait "$deadpid" 2>/dev/null # a reaped child -> dead
echo "$deadpid" > "$dtmp"
gci_daemon_alive "$dtmp"; check "daemon-dead-pid"  "1" "$?"
: > "$dtmp"                                          # empty pidfile -> not alive
gci_daemon_alive "$dtmp"; check "daemon-empty"     "1" "$?"
rm -f "$dtmp"                                        # missing pidfile -> not alive
gci_daemon_alive "$dtmp"; check "daemon-nofile"    "1" "$?"

exit $fail
