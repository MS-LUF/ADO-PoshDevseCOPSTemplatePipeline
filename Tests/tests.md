# Tests of TemplatePipeline

Integration tests for the job scripts of the template, run with [Pester](https://pester.dev)
6. They execute the scripts **the way the pipeline does** — as a child `pwsh` process, from a
ci-tools copy of the scripts, against a scratch git repository under the system temporary
folder — and assert the exit code, the console output (annotations included) and the produced
artifacts (SBOM, reports, `.nupkg`). They are not unit tests: the scripts are job scripts with
their own `exit`, written for an agent's layout, so the faithful test is the whole invocation.

Nothing is ever written into the working tree: repositories, ci-tools copies, logs and
packages live under `%TEMP%\templatepipeline-tests-<user>` (Linux: `/tmp/...`) and are removed
when a test file ends. A run leaves `git status` unchanged.

## Layout

| File | Job | What is covered |
| --- | --- | --- |
| `pwsh-ci-common.Tests.ps1` | shared code | console-text neutralization, log creation, `Get-CINupkgInfo` |
| `pwsh-ci-template.Tests.ps1` | `pwsh-ci.yml` | item 39, read as text: no parameter in `arguments` or a runtime condition, no inline script, every `$` removed from a value in `env` |
| `pwsh-ci-range.Tests.ps1` | A1, A2, A3 | a missing `origin/main` and a shallow clone stop the job |
| `sec-pwsh-analysis-malicious.Tests.ps1` | A1 | pass/fail on changed files, attack sample with exact counts, also followed by a harmless commit, `internal-ci/` never analysed, wildcard names, `##vso[` neutralization, missing rules, an injected value through `env` (item 39), a file's own suppression (item 40), exceptions of item 38 (valid, branch only, edited file, each invalid entry, not JSON, a pull request merge commit's first parent) |
| `tec-pwsh-analysis-practice.Tests.ps1` | A2 | pass with warning annotations, parse errors, `##vso[` neutralization |
| `biz-pwsh-analysis-pester.Tests.ps1` | A3 | no trigger without a relevant change, pass, failing tests with annotations |
| `tec-pwsh-sbom-inventory.Tests.ps1` | B1 | CycloneDX 1.6 shape, main component, own module with PSGallery purl, lockfile package, non-assembly binary, unversioned dependency warning |
| `sec-pwsh-analysis-cve.Tests.ps1` | B2 | offline: each kind of invalid exceptions entry, on the function taken from the script. `Network`: module-only pass, invalid entries, a vulnerable lockfile package, with and without a valid exception, tampered Grype hash |
| `tec-pwsh-sbom-publish.Tests.ps1` | B3 | every preflight check before the first request; with a stand-in for `Invoke-RestMethod`: upload and polling, a refused key, no token, a timeout, the key never in the console or the log |
| `tec-pwsh-package-pack.Tests.ps1` | C1 | pack on a root and a subfolder manifest, `.git` kept out of the package, symlinks not followed, every fail-closed input check, `publishFeed` assertions, the tag-version warning (item 36), the file URI of a Linux path (item 35), 5.1 (`WindowsPowerShell`) |
| `pub-pwsh-package-push.Tests.ps1` | C2 | every check up to the wire: feed assertions, folder, package count, missing `dotnet`, unreachable feed |

`Helpers.ps1` builds the fixtures: git repositories with a base commit and a local
`origin/main` reference (no remote needed), ci-tools copies, controlled job environment
variables, and the process runner.

## Prerequisites

- `pwsh` 7.4 or later, and `git` on the `PATH`.
- The bundled Pester, imported by path (no installation needed):

  ```powershell
  Import-Module ./internal-ci/Security-PWSH-ADO-ci/Pester
  ```

- The .NET SDK for the C2 unreachable-feed test, which needs `dotnet nuget push` to run and
  skips without it (the hosted images have it). The missing-`dotnet` case takes it off the
  `PATH` itself; without an SDK it passes with nothing to remove.
- Internet access for the `Network` tag only.

## Running

```powershell
Import-Module ./internal-ci/Security-PWSH-ADO-ci/Pester

# the suite as CI would run it (offline cases):
Invoke-Pester ./Tests -ExcludeTagFilter Network

# everything, the Grype-downloading tests included (a few minutes, ~3.3 GB transient):
Invoke-Pester ./Tests

# one job only:
Invoke-Pester ./Tests/tec-pwsh-package-pack.Tests.ps1

# only the Windows PowerShell 5.1 smoke cases (the runs above include them; they are
# skipped where powershell.exe is missing, e.g. Linux agents):
Invoke-Pester ./Tests -TagFilter WindowsPowerShell
```

## Tags

| Tag | Meaning | Cost |
| --- | --- | --- |
| `Network` | B2 downloads Grype and one vulnerability database, shared by its scans | a minute or three, ~300 MB download, ~3.3 GB of temp while running (removed by the test file) |
| `WindowsPowerShell` | runs the case under `powershell.exe` 5.1 too | skipped automatically on non-Windows hosts |

The tests self-skip gracefully: `Network` tests skip when the machine is offline; the
symlink case skips where the account cannot create links.

## Not covered (and why)

- **The bundled tools** under `internal-ci/` (PSScriptAnalyzer, Pester, the rule generator,
  PSResourceGet): they are third-party code, tested upstream.
- **The real pushes**: C2 pushing to Azure Artifacts, including the duplicate-version refusal
  (403/409), and B3 uploading to a real Dependency-Track over `https` — both need a live
  server and are verified by the owner's runs.
- **A real pull request build** (backlog item 4): the suite builds a merge commit locally and
  sets `BUILD_REASON`; what Azure DevOps really gives a PR build needs a run there.
- **Attack strings in this repository**: per the project's directive, the A1 attack sample is
  the module's own `internal-ci/Samples/BaselineSample.txt`, read as data at run time (whole, or
  one line of it) and written into the scratch repository. No `.ps1` here holds attack code.

When this repository's own pipeline runs on the template, stage A3 runs this suite: the
fixtures are plain PowerShell, Pester 6 runs them, and the `Network` tests honour the
machine's connectivity.
