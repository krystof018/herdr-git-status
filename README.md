# GitLab & GitHub CI Status — herdr plugin

Surfaces CI status inside herdr — for both **GitLab** (pipelines + merge requests via `glab`) and
**GitHub** (check runs + pull requests via `gh`), auto-detected from each repo's `origin` host — two
ways:

1. **Live status dots in the spaces sidebar** — a background poller prefixes each space's label with a
   colored dot for its current branch's latest CI run (🟢 passed · 🟡 running · 🔴 failed · ⚪ none), plus
   the open request number (`!123` for a GitLab MR, `#123` for a GitHub PR) when the branch has one. It
   only edits the label text and never touches the agent status dot.
2. **An on-demand detail pane** — project, current branch, the latest pipeline/run status,
   the open MR/PR, and a list of the most recent **failed** pipelines/runs for the branch
   (up to 5). The project path, each run/pipeline `#id`, and the `!123`/`#123` are clickable
   OSC 8 hyperlinks (Ctrl/Cmd-click) — the raw URLs aren't printed.

```
 GitLab CI · gitlab.com/myteam/my-service

 Project   myteam/my-service          ← links to the project page
 Branch    feature/checkout-flow

 Pipeline  #1284913   ✓ passed        ← #id links to the pipeline
 Updated   2m ago
 MR        !123                       ← links to the merge request

 Recent failures
   #1284901   ✗ 2h ago                ← each #id links to that pipeline
   #1284866   ✗ 5h ago

 r refresh · q quit · auto-refresh 15s
```

…and for a GitHub repo:

```
 GitHub CI · github.com/acme/web-app

 Project   acme/web-app               ← links to the repo
 Branch    feature/checkout-flow

 Run       #28165711782   ✓ passed    ← #id links to the decisive check run
 Updated   2m ago
 PR        #123                       ← links to the pull request

 Recent failures
   #28165700001   ✗ 3h ago            ← each #id links to that run
   #28165611120   ✗ 1d ago

 r refresh · q quit · auto-refresh 15s
```

In the sidebar, those spaces show as `🟢 !123 my-service` and `🟢 #123 web-app`.

The open MR/PR number is also prefixed with a **review-state glyph** when the merge request
needs attention or is ready: `💬` changes requested / unresolved threads · `⚠️` merge conflict
(needs rebase) · `✅` approved & mergeable (ready to merge). Drafts and MRs merely awaiting
review show the plain `!123` / `#123` with no glyph. So a space might read `🟢 ✅!123 my-service`
(green pipeline, MR approved) or `🔴 💬!88 billing-api` (red pipeline, changes requested).

## Requirements

- **herdr** ≥ 0.7
- **jq** and **git**
- A provider CLI for whichever remotes you use, authenticated:
  - **glab** (GitLab CLI) — `glab auth login` — for GitLab repos
  - **gh** (GitHub CLI) — `gh auth login` — for GitHub repos

You only need the CLI for the hosts you actually use (jq + git are always required). On macOS:
`brew install jq git glab gh`. The plugin stores no tokens of its own — it reuses glab/gh auth.

## Install

```sh
herdr plugin link /path/to/this/plugin
herdr plugin list        # confirm "gitlab-ci-status" is registered
```

`herdr plugin link` is for local development and runs no build step — none is needed (pure Bash).

## Keybindings (one-time setup)

herdr 0.7 does **not** bind keys declared in a plugin manifest, so add the bindings to your
`~/.config/herdr/config.toml` and run `herdr server reload-config`:

```toml
[[keys.command]]
key = "prefix+i"
type = "shell"
command = "herdr plugin action invoke gitlab-ci-status.toggle"

[[keys.command]]
key = "prefix+shift+i"
type = "shell"
command = "herdr plugin action invoke gitlab-ci-status.open"

[[keys.command]]
key = "prefix+r"
type = "shell"
command = "herdr plugin action invoke gitlab-ci-status.open-mr"
```

(`prefix` is `ctrl+b`. You can also trigger the actions any time without a keybinding via
`herdr plugin action invoke gitlab-ci-status.<toggle|start|stop|open|open-mr>`.)

## Usage

**Sidebar dots:** `ctrl+b` then `i` toggles the poller on/off. While on, every space's label gets a
colored CI dot, refreshed every 30s. Toggling off (or `herdr plugin action invoke
gitlab-ci-status.stop`) removes the dots and restores your original labels.

**Detail pane:** `ctrl+b` then `Shift+I` in a GitLab or GitHub workspace opens a split pane showing the
project link, branch, latest pipeline/run, and open MR/PR. In the pane: **`r`** refresh, **`q`** quit
(`Ctrl-C` also closes it). The branch is re-read every refresh, so switching branches updates
automatically.

**My MRs pane:** `ctrl+b` then `r` opens a pane listing **your own** open MRs/PRs across every
repo, aggregated from each provider you're authenticated with (GitLab via `glab`, GitHub via
`gh`), in two sections — **Ready to merge** (approved & mergeable) and **Needs action** (changes
requested / unresolved threads, or merge conflict). Each MR id is a clickable OSC 8 link. In the
pane: `r` refresh, `q` quit (Ctrl-C also closes), auto-refresh 15s. Always invokable via
`herdr plugin action invoke gitlab-ci-status.open-mr`.

> **Note on branch vs MR/PR pipelines:** status is looked up for the current *branch* (GitLab pipelines
> by `ref`; GitHub aggregates all check runs on the branch head — the most severe one wins, so one
> skipped workflow can't mask a green or running push). GitLab projects that run CI only as merge-request
> pipelines (common in some GitLab setups) show ⚪ on a feature branch until it has a branch pipeline.

## Configuration

Optional. Put a `.env` file in the plugin's config dir (honored by both the pane and the poller):

```sh
echo "GITLAB_CI_REFRESH=20" >> "$(herdr plugin config-dir gitlab-ci-status)/.env"
```

- `GITLAB_CI_REFRESH` — refresh interval in seconds (pane default `15`, poller default `30`).

To change keybindings, edit the `[[keys.command]]` entries in your `config.toml` (see above). For pane
placement, edit `herdr-plugin.toml` and re-link.

## How it works

The `open` action reads the workspace's working directory from `HERDR_PLUGIN_CONTEXT_JSON`
(`focused_pane_cwd`, falling back to `workspace_cwd`) and opens the `ci` pane there. The pane parses the
`origin` remote, picks a provider from the host (`*gitlab*` → glab, `*github*` → gh), reads the current
branch, and queries that provider for the latest CI run and the open MR/PR:

- **GitLab:** `glab api "projects/<path>/pipelines?ref=<branch>"` (latest + a second call
  with `&status=failed` for the recent-failures list) and
  `glab api "projects/<path>/merge_requests?source_branch=<branch>&state=opened"`.
- **GitHub:** `gh api "repos/<owner>/<repo>/actions/runs?branch=<branch>"` (latest + a second
  call with `&status=failure` for the recent-failures list) and
  `gh api "repos/<owner>/<repo>/pulls?head=<owner>:<branch>&state=open"`.

glab/gh supply authentication and the host; the plugin stores no tokens of its own.

The poller (`poller-ctl.sh run`, launched detached by the `start`/`toggle` actions) loops every
`GITLAB_CI_REFRESH` seconds: for each space it finds a pane cwd via `herdr pane list`, fetches the
latest run and open MR/PR the same way, maps the status to a dot, and `herdr workspace rename`s the
space to `"<dot> <sigil><num> <original label>"`. The original label is recovered each cycle by
stripping any existing CI dot and `!`/`#` token, so it is idempotent and survives your own renames.
`stop` kills the loop and restores all labels.

## Files

| File | Purpose |
|------|---------|
| `herdr-plugin.toml` | Manifest: actions (`open`/`open-mr`/`start`/`stop`/`toggle`), the `ci` and `mr` panes, and keybindings. |
| `poller-ctl.sh` | Always-live poller maintaining the colored CI dot on each space label: `start`/`stop`/`toggle`/`status`. |
| `open.sh` | Resolves the repo dir from workspace context and opens the detail pane. |
| `ci-pane.sh` | The detail pane's live fetch → render → sleep loop (`GITLAB_CI_ONCE=1` for one-shot output). |
| `open-mr.sh` | Resolves the repo context and opens the "My MRs" pane. |
| `mr-pane.sh` | The "My MRs" pane: my open MRs/PRs across providers, grouped ready / needs-action. |
| `lib.sh` | Shared helpers: remote parsing, provider detection, GitLab/GitHub CI + MR/PR fetch, recent-failures fetch, provider-aware pane label, status glyph/emoji, relative time, hyperlink, env loader. |
| `test.sh` | Unit tests for `lib.sh`. Run with `bash test.sh`. |
