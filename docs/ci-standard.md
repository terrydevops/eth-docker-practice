# CI standard

The CI rules this repo follows. The same standard covers my other practice
repos; this copy holds the parts that apply here: Baseline and Containers.
Sources: [OpenSSF Scorecard](https://github.com/ossf/scorecard/blob/main/docs/checks.md),
GitHub's *Security hardening for GitHub Actions*, and the
[zizmor](https://docs.zizmor.sh/audits/) audits.

A rule that is not met is listed under "Gaps" with the reason.

## Baseline

| ID | Rule | Why |
|---|---|---|
| B1 | Top-level `permissions: contents: read`; writes granted per job | least token for a compromised step |
| B2 | Actions pinned to a commit sha; tool images by digest | tags move, shas do not |
| B3 | Dependabot keeps the pins current | a pin that never moves collects CVEs |
| B4 | `actions/checkout` with `persist-credentials: false` | no token left in `.git/config` |
| B5 | actionlint and zizmor on every change | broken expressions, injection, dangerous triggers |
| B6 | Untrusted values reach `run:` only through `env:` | `${{ }}` in `run:` is shell injection |
| B7 | yamllint `--strict`, shellcheck | cheap, catches real mistakes |
| B8 | Secret scan of the tree | a leaked key is found before it spreads |
| B9 | Hygiene script: English only, no AI attribution in this repo | one script enforces the repo's rule |
| B10 | Superseded runs are cancelled | stale checks waste minutes |
| B11 | Weekly scheduled run | pins do not change, advisories do |
| B12 | Runner image pinned (`ubuntu-24.04`); `timeout-minutes` on every job | no silent image change, no 6 h hung job |
| B13 | `main` protected: no force-push, no deletion | history cannot be rewritten or lost |
| B14 | `LICENSE` and `SECURITY.md` | how to report a problem |

## Containers

| ID | Rule | Why |
|---|---|---|
| C1 | Every image reference pinned, checked by a script | no floating tag reaches the devnet |
| C2 | Image CVE scan: CRITICAL, ignore unfixed; accepted findings have a reason and an expiry | the weekly run fails once an expiry passes |
| C3 | Compose files render; Prometheus rules and rule tests pass | broken config fails before it is started |

## Where each rule is met

| ID | Where |
|---|---|
| B1, B2, B4, B6, B10, B11, B12 | `.github/workflows/security.yml` |
| B3 | `.github/dependabot.yml` (github-actions) |
| B5, B7, B9 | `security.yml`, `lint` and `zizmor` jobs; B9 is `.github/scripts/hygiene.sh` |
| B8 | `security.yml`, `secrets` job (trivy, `trivy-secret.yaml`) |
| B13 | branch protection on `main`: force-push and deletion blocked |
| B14 | `LICENSE`, `SECURITY.md` |
| C1 | `.github/scripts/list-images.sh --check` |
| C2 | `security.yml`, `image-scan` job, `.trivyignore.yaml` |
| C3 | `.github/scripts/compose-config.sh`, promtool steps in `lint` |

## Gaps

| ID | Gap | Why |
|---|---|---|
| B3 | dependabot does not update the client images | they are set through `${VAR}` and the devnet pin file, which dependabot cannot read; upgrades are done by hand with a soak, and C2 flags the ones that matter |
| B13 | no required checks before a push to `main` | changes go straight to `main`; a failed check turns the commit red but does not block it |
| C1 | client images are pinned to exact tags, not digests | `list-images.sh --check` rejects floating tags; the CI tool images are pinned by digest |
