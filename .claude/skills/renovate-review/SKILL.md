---
name: renovate-review
description: This skill should be used when the user wants a review of open Renovate PRs/dependency updates in this homelab repo — checking each pending update's changelog for breaking changes, what's new, or whether it's safe to merge. Triggers on "renovate", "review renovate PRs", "dependency updates", "what's breaking in the updates", "changelog check", "dependency dashboard", "/renovate-review". Strictly read-only against GitHub — never merges, closes, comments on, or rebases a PR, and never touches git in this repo.
---

# Renovate PR review

Collects every open Renovate PR in `glazrtom/homelab`, resolves each dependency's real
upstream changelog (Renovate's own PR body has no release notes — just the version bump),
fans out one subagent per dependency to read the changelogs for every version in range, and
prints one consolidated report: breaking changes and notable updates per service. Nothing is
written anywhere — no file saved, no PR touched.

## Why every `gh` call must stand alone

Per this repo's CLAUDE.md, `.claude/settings.json`'s `excludedCommands` unsandboxes a Bash
call only when the **entire command string** is `gh ...` — no pipe, no `;`/`&&`, no second
command, no wrapper script. Break that and the call runs sandboxed instead, where
`~/.config/gh` (holding the token) is unreadable and the call fails with
`operation not permitted`. So: one `gh` invocation per Bash call, trim with `gh`'s own
`--json`/`--jq`/`--search`/`--limit` instead of piping, and run independent `gh` calls as
separate **parallel** Bash calls (multiple tool calls in one message) rather than chaining
them. This is also why this skill has no helper script — a script wrapping `gh` would hit
the same sandboxing.

## Step 1 — collect open Renovate PRs

One call:

```
gh pr list --repo glazrtom/homelab --author app/renovate --state open --limit 100 \
  --json number,title,headRefName,url,body \
  --jq '.[] | "\(.number)\t\(.headRefName)\t\(.body | capture("\\n\\| (?<row>\\[.*)\\n") | .row)"'
```

Each output line is `number, branch, package-link | update-type | from → to`. A PR whose
body doesn't match that table shape (a digest pin, a custom regex manager with no upstream
link) fails the `capture` silently for that line — re-fetch those individually with
`gh pr view <n> --repo glazrtom/homelab --json title,body,files`.

Optionally also check the Dependency Dashboard issue for updates Renovate has detected but
not yet opened a PR for (rate-limited, `prConcurrentLimit: 0` throttling, etc.) — list them
in the report as "pending, no PR yet", don't analyse their changelogs:

```
gh issue list --repo glazrtom/homelab --search "Dependency Dashboard in:title" --state open --json number,title,body
```

## Step 2 — group

- **Service** = the `<parentDir>` prefix in the branch name, `renovate/<parentDir>-...`
  (set by `additionalBranchPrefix` in `renovate.json`) — e.g. `media`, `monitoring`,
  `authentik`, `longhorn`, `install` (→ the ArgoCD install manifest, i.e. argo-cd itself),
  `core` (→ reflector), `workflows` (→ GitHub Actions).
- **Dependency** = one upstream package. If more than one open PR targets the same package
  (e.g. an argo-cd patch PR and a separate argo-cd minor PR, or two alpine/k8s PRs at
  different targets), treat them as one review task covering the union of versions crossed;
  note in the report which PR number is the one to actually merge (normally the one with the
  higher target) and that the other is superseded.

## Step 3 — resolve each dependency's real changelog source

Renovate's PR-body `([source](...))` link is usually right — follow the redirect
(`redirect.github.com/<owner>/<repo>` → `github.com/<owner>/<repo>`). Known overrides in this
repo (mirrors `renovate.json`'s `packageRules[].sourceUrl`, plus a few not worth encoding
there):

| Dependency | Real changelog source |
|---|---|
| `linuxserver/jellyfin`, `radarr`, `sonarr`, `prowlarr` | Upstream app repo, not the container repo: `jellyfin/jellyfin`, `Radarr/Radarr`, `Sonarr/Sonarr`, `Prowlarr/Prowlarr` releases |
| `pihole/pihole` | `pi-hole/docker-pi-hole` releases (calver `YYYY.MM.N`) |
| `authentik` (helm chart) | `goauthentik/authentik` releases, **and** `docs.goauthentik.io/docs/releases/<YYYY.M>` for every minor crossed — breaking changes are documented there, not just in the GitHub release body |
| `kube-prometheus-stack` (helm chart) | `prometheus-community/helm-charts` releases, tag `kube-prometheus-stack-<ver>`; for a major bump also check the chart's `README.md` "Upgrading" section at that tag |
| `longhorn` (helm chart) | `longhorn/longhorn` releases, plus longhorn.io upgrade docs for the crossed minor |
| `argoproj/argo-cd` | `argoproj/argo-cd` releases, plus the upgrade guide at `github.com/argoproj/argo-cd/blob/master/docs/operator-manual/upgrading/<x.y>-<x.z>.md` for each minor crossed |
| `reflector` (helm chart) | `emberstack/kubernetes-reflector` releases |
| `linuxserver/calibre-web` (digest pin) | No changelog — `pinDigests: true` means these PRs just pin+bump a digest on a floating tag; report as "digest pin, nothing to review", don't spawn a subagent |
| everything else | The `([source](...))` link from the PR body, or the package name itself if it's already a GitHub-style `owner/repo` |

Fetching releases for a resolved `owner/repo`:

```
gh api "repos/<owner>/<repo>/releases?per_page=100" --jq '.[] | {tag_name, published_at, body}'
```

Keep every release strictly after `from` up to and including `to`; page with
`&page=2` etc. if `from` isn't reached in the first page. If the repo has no GitHub
Releases (some use only a `CHANGELOG.md`), fetch that file instead:
`gh api repos/<owner>/<repo>/contents/CHANGELOG.md --jq .content` (base64-decode) or
WebFetch the rendered file.

## Step 4 — fan out one subagent per dependency

Spawn all of them in a **single message** (parallel `Agent` calls), `subagent_type:
"general-purpose"`, `model: "sonnet"`. Skip spawning for trivial cases — a patch bump with
one release between `from` and `to`, or a digest-pin PR — and just fill those rows in
directly instead.

Give each subagent this prompt shape:

```
Read-only research task, no git/PR actions of any kind. In the glazrtom/homelab repo,
package `<dep>` (service: `<service>`) is being bumped by Renovate PR(s) <#n, url> from
`<from>` to `<to>` (<update type>).

Read the changelog/release notes for every version strictly after <from> up to and
including <to>, from: <resolved source url(s) from Step 3>. Use gh api / WebFetch as
needed. Remember: any `gh` call must be a single standalone command with no pipes or
chaining.

Look for: anything the notes call BREAKING, deprecated, removed, renamed; migration
steps; new minimum-version requirements (Kubernetes, Helm, a database, an app's own
config schema); security advisories fixed. Don't invent a breaking change if the notes
don't mention one — "none found" is a valid, expected answer.

Return exactly this, nothing else:

### <package> <from> → <to> (PR #<n>, <update type>)
Verdict: SAFE | REVIEW | BREAKING
Breaking changes:
- <version>: <what>   (or "- none found")
Notable:
- <version>: <feature/fix/security note>   (or "- none")
Upgrade steps / manual action:
- <step>   (or "- none")
Sources: <urls actually read>
Gaps: <versions whose notes couldn't be fetched, or "none">
```

## Step 5 — report

Print to the terminal only — do not save a file under `reports/`, do not comment on or
rebase any PR.

1. Summary table, sorted `BREAKING` → `REVIEW` → `SAFE`:
   `Service | PR(s) | Package | from → to | Type | Verdict`.
2. One section per service (grouped by the Step 2 service name), each containing its
   subagents' full blocks verbatim.
3. Short closing paragraph: call out every `BREAKING` item first, then any superseded
   duplicate PR (state which PR # to actually merge), then anything with a required merge
   order or manual step (e.g. argo-cd upgrading itself, longhorn's upgrade path, authentik
   outpost versions needing to track the server version — see the `authentik-ingress`
   skill), then pending Dashboard items with no PR yet.

## Notes

- This repo has no CI that runs on these PRs beyond `.github/workflows/deploy.yml`'s
  ArgoCD sync — merging is a manual human decision after reading this report.
- `automerge: false` and `prHourlyLimit: 0` in `renovate.json` mean nothing here merges
  itself; this skill doesn't change that.
- If a subagent can't reach a source (private repo, no releases, blocked domain), have it
  say so in `Gaps` rather than silently omitting the dependency from the report.
