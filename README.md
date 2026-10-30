# ADO-PoshDevSecOPSTemplatePipeline

Azure Pipelines extends template for the CI of PowerShell repositories: security analysis with the [Initialize-ASTRule rules](https://github.com/MS-LUF/Initialize-ASTRuleGenerator), coding-practice analysis with PSScriptAnalyzer, the repository's Pester tests, its SBOM, and a check of its components for known vulnerabilities, and packs and publishes its PowerShell module as a NuGet package.

(c) 2021-2026 lucas-cueff.com Distributed under Artistic Licence 2.0 (https://opensource.org/licenses/artistic-license-2.0).

**Step by step** (bring the template into your organization or collection, protect it and release it, create a repository that uses it, enforce it, on Azure DevOps Services or Server): [howto.md](howto.md).

## What the stages do
| Job | Script | Fails when |
| --- | --- | --- |
| A1 - security | `sec-pwsh-analysis-malicious.ps1` | a changed `.ps1`/`.psm1`/`.psd1` file raises an Error finding of the Initialize-ASTRuleGenerator rules, or does not parse |
| A2 - coding practice | `tec-pwsh-analysis-practice.ps1` | a changed file raises an Error finding of the default PSScriptAnalyzer rules, or does not parse |
| A3 - Pester | `biz-pwsh-analysis-pester.ps1` | a test fails; runs after A1 and A2, only when PowerShell code or the test folder changed |
| B1 - SBOM | `tec-pwsh-sbom-inventory.ps1` | never on findings: writes the SBOM (CycloneDX 1.6) of the tested commit, published as the artifact `tec-pwsh-sbom` |
| B2 - known vulnerabilities | `sec-pwsh-analysis-cve.ps1` | a component has a High or Critical CVE/GHSA that has a fix; the report is published as the artifact `sec-pwsh-cve-report` |
| B3 - SBOM to Dependency-Track | `tec-pwsh-sbom-publish.ps1` | on the base branch only, when `dependencyTrackVariableGroup` is set: Dependency-Track is unreachable, refuses the key or the SBOM, or does not process it within 5 minutes |
| C1 - package pack | `tec-pwsh-package-pack.ps1` | `publishFeed` is empty or not `https`, the manifest is missing or invalid, has no `ModuleVersion`, or the pack fails; runs on every build `publishPackage` is on, after stages A and B, and publishes the `.nupkg` as the artifact `pub-pwsh-package` |
| C2 - package push | `pub-pwsh-package-push.ps1` | on tag builds only: the feed is unreachable, refuses the package (a version already published), or `dotnet` is missing |

Stage B (B1 and B2) runs on every build, the base branch included, next to stage A; `runSupplyChain: false` turns it off. B3 runs only on the base branch, and only when you set `dependencyTrackVariableGroup` (see "Publish the SBOM to Dependency-Track"). Stage C (C1 and C2), opt-in with `publishPackage: true`, packs the module on every build, after stages A and B, and pushes it on tag builds only (see "Publish the module to a NuGet feed").

- **Changed files** are those between the tested commit and its merge-base with the base branch (the target branch for a pull request), so every commit of a branch is covered.
- **The scripts, rules and tools run from this repository**, never from the repository under test: a branch cannot change its own scanner, rules or allow-list.
- **Tools** are bundled under `internal-ci/Security-PWSH-ADO-ci/`: PSScriptAnalyzer 1.25.0, Pester 6.2.0 and the Initialize-ASTRuleGenerator module 1.1.1 with its rules, and Microsoft.PowerShell.PSResourceGet 1.1.0 packs the package (C1). Nothing is downloaded while they are present; a missing PSScriptAnalyzer or Pester is taken from the agent, then from PSGallery.
- **Shared code**: the job scripts dot-source `pwsh-ci-common.ps1` (logging, the changed files, the tool import, the annotations).
- **Logs**: each job writes `Logs/*.log`; a failed job publishes them as a build artifact, and A3 publishes `Logs/pester-testresults.xml` as test results.
- **Annotations**: each A1/A2 finding (error or warning, by severity) and each failed test, block or test file of A3 also shows in the build summary, at its file and line.

## Use it
```yaml
trigger:
  batch: true
  branches:
    include:
    - '*'

resources:
  repositories:
  - repository: TemplatePipeline # the alias the template checks out: keep it
    type: git
    name: LABIA/TemplatePipeline
    ref: refs/tags/v1.7.0 # a release tag; move it to take a newer release

extends:
  template: pwsh-ci.yml@TemplatePipeline
  parameters:
    baseBranch: main  # default
    testPath: Tests   # default
    securityExceptionsFile: '' # default: .security/a1-exceptions.json, A1's false-positive exceptions, read from the base branch only
    runPester: true   # default
    runSupplyChain: true # default: stage B, the SBOM and the known-vulnerability check
    vmImage: ubuntu-latest # default: the Microsoft-hosted image
    poolName: ''      # default; set it to run on a self-hosted pool (required on Azure DevOps Server)
    dependencyTrackVariableGroup: '' # default; set it to publish the SBOM to Dependency-Track (B3)
    dependencyTrackProjectName: ''   # default: the repository's name
    publishPackage: false # default; stage C: pack the module into a .nupkg (C1, every build) and publish it (C2, tag builds)
    packageSpec: ''     # default; the module manifest to pack, relative to the repository root (empty: the single root manifest)
    publishFeed: ''     # required with publishPackage: the feed's https v3 URL (the feed's "Connect to feed" pane)
    publishServiceConnection: '' # default; a NuGet service connection (not an API key) for a feed outside the organization
```

## Tests
The job scripts have an integration test suite in [`Tests/`](Tests/tests.md) (Pester 6): each
script is executed the way the pipeline runs it, against scratch git repositories under the
temporary folder, with assertions on exit codes, annotations and artifacts (SBOM, reports,
`.nupkg`). Nothing is written into the working tree.

```powershell
Import-Module ./internal-ci/Security-PWSH-ADO-ci/Pester   # the bundled Pester
Invoke-Pester ./Tests -ExcludeTagFilter Network           # as CI would run it
```

The `Network` tag (B2 downloads Grype and its database) and `WindowsPowerShell` (smoke cases
under 5.1) self-skip where their prerequisites are missing. See
[Tests/tests.md](Tests/tests.md) for the coverage, the layout and what is not tested.
## Publish the SBOM to Dependency-Track
Job B3 sends the SBOM of each base-branch build to a [Dependency-Track](https://dependencytrack.org/) server (5.x, or 4.11.4 or later): one project per repository, named after the repository (or `dependencyTrackProjectName`), at the version named after the base branch (for example `main`), marked as the latest. Each upload replaces that version's components. The project is created on the first upload, tagged with the Azure DevOps project. B3 waits until Dependency-Track has processed the SBOM, and fails the build on any error.

1. **In Dependency-Track:** a team with the permissions `BOM_UPLOAD` and `PROJECT_CREATION_UPLOAD`, and an API key for it. Nothing else: the tag is set when the project is created, and later uploads leave the project's tags alone.
2. **In Azure DevOps:** a variable group (*Pipelines > Library*), for example `dependency-track`, with:
   - `DependencyTrackUrl`: the API server's address, `https` only, without `/api` (for example `https://dtrack.example.com`);
   - `DependencyTrackApiKey`: the key, as a **secret**.
3. **Protect the group** (*Approvals and checks* on the group): a **Branch control** check that allows only `refs/heads/main` (your base branch), and a **Required template** check on this repository at the release tag, `pwsh-ci.yml`. The key then never reaches a branch build, nor a pipeline that does not extend this template.
4. **Set** `dependencyTrackVariableGroup: dependency-track` in the pipeline, and authorise the group on its first base-branch run.

Keep the URL in the group: a URL in the pipeline file could be changed by a branch to a server that receives the key. B3 runs only on base-branch builds, and only checks out this repository: it reads the SBOM that B1 wrote, and runs no code of the repository.

## Publish the module to a NuGet feed
Jobs C1 and C2 (stage C, `publishPackage: true`) pack the repository's PowerShell module into a
`.nupkg` on every build and push it to a NuGet feed on tag builds only: the tag is the release.
The version is the manifest's `ModuleVersion`; the feed refuses a version already published, so
releasing means bumping the manifest, then tagging that commit. Base-branch builds pack but do
not push: if they did, the tag build of the same commit would fail on the duplicate.

1. **In Azure Artifacts:** a feed, with the **build service account** (the identity the pipeline
   runs as — `<project> Build Service (<org>)`, or the collection-scoped *Project Collection
   Build Service*) in the **Feed Publisher** role on that feed, and on no other feed you do not
   mean to publish to. That role is the whole credential: the `NuGetAuthenticate` task uses the
   build identity's own token, so there is no PAT and no secret to rotate.
2. **Set** `publishPackage: true` and `publishFeed:` the feed's v3 URL, from the feed's
   *Connect to feed* pane (for example
   `https://pkgs.dev.azure.com/<org>/<project>/_packaging/<feed>/nuget/v3/index.json`).
   `packageSpec` names the manifest when it is not the single `.psd1` at the repository root.
   C1 checks `publishFeed` on every build, so a missing or non-`https` feed fails a pull request
   before the merge.
3. **Trigger on tags:** without a tag trigger, pushing a tag starts no build and nothing is
   published. Add your release tag pattern to the pipeline's `trigger`:
   ```yaml
   trigger:
     batch: true
     branches:
       include:
       - '*'
     tags:
       include:
       - 'v*'
   ```
4. **For a feed outside the organization:** a NuGet service connection (the feed's URL and a
   PAT with *Packaging > Read & write*, as a username/password or token connection), named in
   `publishServiceConnection`; protect the connection with a **Branch control** check that
   allows your release tags (`refs/tags/v*`) and a **Required template** check, as B3's
   variable group. An API-key connection does not work (`NuGetAuthenticate` does not take
   one), so nuget.org and PSGallery are out of reach.

C1 runs the branch's manifest, so it guards quality like A3: stage C runs only after stages A
and B succeeded (or A was skipped, on the base branch), the push happens only on tag builds,
and the build identity can publish only where it holds the Publisher role. Limit who can create
tags: creating one is what publishes.

## Azure DevOps Server and self-hosted agents
Azure DevOps Server has no Microsoft-hosted agents: set `poolName` to a self-hosted pool. [howto.md](howto.md) walks through the setup, step 0 for the pool and its agents. The template needs Azure DevOps Server 2020 or later (`extends` templates, multi-repository checkout); the extending pipeline and this repository must be Azure Repos Git repositories of the same collection.

Each agent of the pool needs:
- **Linux, with `pwsh` 7.4 or later on the `PATH`** (Pester 6 needs 7.4), `git` and `tar`.
- **Outbound HTTPS for stage B:** `github.com` and its release downloads (`objects.githubusercontent.com`, `release-assets.githubusercontent.com`) for Grype, and `grype.anchore.io` for its database. PSGallery is contacted only when a bundled tool is missing. Without internet access, stage A works with the bundled tools; set `runSupplyChain: false`.
- **Behind a web proxy:** the agent's own proxy setting does not reach the scripts. Set `HTTPS_PROXY` (and `NO_PROXY` for the server) in the agent's `.env` file; PowerShell and Grype both read them. A TLS-inspecting proxy's CA must be in the system trust store.
- **About 3.3 GB free** in the agent's temporary folder while B2 runs (Grype and its database, removed when the job ends).
- **The .NET SDK on the `PATH` for stage C only** (C2 pushes with `dotnet nuget push`; C1 packs
  with the bundled PSResourceGet). The Microsoft-hosted images have it; a self-hosted agent
  needs it installed.

**Use single-use agents, or keep A3 apart.** A3 runs the branch's own tests. A Microsoft-hosted agent is discarded after each job; a self-hosted agent that is reused lets that code change the machine for the next jobs (the agent user's git configuration, PowerShell modules, or the agent's cached tasks) and so make A1 or A2 of a later build, of any repository, pass. Run each job on a fresh agent (for example an agent container started with `--once` and recreated after each job), or set `runPester: false` so that no code of the branch runs. Every checkout of the template cleans its folder (`clean: true`), so the work folder itself starts clean.

## Good to know
- The jobs need the full history (the template sets `fetchDepth: 0`) and run on `ubuntu-latest` (`vmImage` parameter), or on the pool `poolName`: Pester 6 needs PowerShell 7.4 or later.
- The first run asks to authorise the pipeline to read this repository.
- **`ciToolsRoot` is not a setting:** it is where the template's scripts sit in its checkout, and it accepts only its default. Leave it out of your pipeline. A copy of the template hosted in a subfolder of another repository changes it (see [howto.md](howto.md), step 1), with what sharing a repository means for the template's protection and releases.
- **Releases** are annotated tags on `main` (`v1.0.0`, ...); the tag message holds the release notes. A pipeline gets a new release, including new A1 rules, only when its `ref` moves to the new tag. A pushed tag is never moved or deleted.
- To enforce the template, add a **Required template** check (this repository, the release tag such as `refs/tags/v1.7.0`, `pwsh-ci.yml`) to a protected resource the pipelines use, and update it with each release. Protect `main` with a branch policy, and deny **Force push** on *All tags* to everyone but the maintainers, so that a tag cannot be recreated on another commit.
- **A3 checks quality, not security:** the tests are the branch's own code, so a branch can make them pass. Only A1 and A2 are out of its reach, and A3 runs after both.
- **`.ps1xml` files are not analysed:** type and format files can hold code run when a module loads, but PSScriptAnalyzer cannot analyse XML. Review them by hand.
- **The SBOM** lists the PowerShell modules the repository declares (`RequiredModules`, `NestedModules`, `#Requires -Modules`), its own modules, its `.dll` and `.exe` files with their SHA-256 (a .NET assembly under its NuGet ID), and its `packages.lock.json` packages. Nothing from the repository is run. Pin modules with `RequiredVersion`: a module without an exact version is a warning.
- **The known-vulnerability check** downloads Grype (an exact version, checked against its SHA-256) and its vulnerability database on each run (about 200 MB), and stops if either download fails or the database is more than 5 days old. It scans the SBOM and the repository's other lockfiles (npm, pip, Go...). A finding without a fix, or below High, is a warning.
- **Not checkable for CVEs:** PowerShell modules (no vulnerability database covers the PowerShell Gallery; the report lists them), binaries that are not .NET assemblies, and code copied in without a manifest or lockfile.
- **A1's false positives** go in `.security/a1-exceptions.json` (or the file `securityExceptionsFile` names): one entry per rule and file, with the file's SHA-256, a reason and an expiry at most a year ahead. A1 reads the file **from the base branch only**, so an exception must be merged before the change it excuses; the Error findings it covers become warnings that show the reason, while the file keeps that hash. An invalid or expired entry fails A1. See [howto.md](howto.md), step 3.3.
- **Accepted risks** go in `.supplychain/cve-exceptions.json`, one entry per vulnerability and package, each with a reason and an expiry at most a year ahead; an invalid or expired entry fails the job. Protect the file with your branch policy.

  ```json
  { "exceptions": [ { "id": "GHSA-5crp-9r3c-p9vr", "package": "Newtonsoft.Json", "reason": "Input depth is limited by the caller.", "expires": "2027-03-31" } ] }
  ```
- **The package version is the manifest's `ModuleVersion`**, and the feed refuses an existing
  version: a push that duplicates a published version fails, telling you to bump the manifest.
  C1 packs on every build; C2 pushes on tag builds only. On a tag build, C1 warns (in the log
  and the build summary) when the tag's version differs from the package's: the tag's version
  is the part of its name after the last `/`, without a leading `v`, so `v1.2.3`,
  `release/1.2.3` and `MyModule/1.2.3` all name `1.2.3`. The package is still published, under
  the manifest's version.
- **The package holds the module's own files only:** C1 packs from a staging copy of the
  module folder — the checkout's `.git` and symlinks never go in.
- `internal-ci/Samples/` holds an attack sample, as text, for checking A1 locally. The jobs never read or run it.
- A newer Initialize-ASTRuleGenerator module or rules set replaces `internal-ci/Security-PWSH-ADO-ci/Initialize-ASTRuleGenerator/` and goes out as a new release.
