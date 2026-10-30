# How to use TemplatePipeline

This guide sets up TemplatePipeline from scratch, on **Azure DevOps Services** (the cloud,
`dev.azure.com`) or on **Azure DevOps Server** (on-premises, 2020 or later):

1. bring the template repository into your organization or collection;
2. protect it and publish a release tag;
3. create a PowerShell repository that uses it;
4. enforce the template;
5. take a new release later.

The examples use the project `LABIA` and the repository `TemplatePipeline`; replace them with
yours. Where Services and Server differ, each step says so.

| | Azure DevOps Services | Azure DevOps Server |
| --- | --- | --- |
| Address | `https://dev.azure.com/<organization>` | `https://<server>/<collection>` |
| Settings level above projects | Organization settings | Collection settings |
| Agents | Microsoft-hosted (`ubuntu-latest`), nothing to install | Self-hosted only: you install the agents (step 0) |
| Template parameter | none needed | `poolName: <your pool>` |

---

## 0. Azure DevOps Server only: an agent pool

Azure DevOps Server has no Microsoft-hosted agents, so every job runs on an agent you host.
On Services, skip this step.

1. **Create the pool:** *Collection settings > Agent pools > Add pool*, type *Self-hosted*,
   for example `pwsh-ci`, and grant access to the projects that will run the pipelines.
2. **Prepare each Linux machine** (a VM or a container image):
   - PowerShell 7.4 or later as `pwsh` on the `PATH` (Pester 6 needs 7.4);
   - `git` and `tar`;
   - about 3.3 GB free in the agent's work folder (job B2 downloads Grype and its database,
     and removes them when it ends).
3. **Install the agent:** in the pool, *New agent > Linux* gives the download and the commands.
   Configure it with a personal access token that has the *Agent Pools (read, manage)* scope:

   ```bash
   ./config.sh --unattended --url https://<server>/<collection> --auth pat --token <PAT> \
     --pool pwsh-ci --agent "$(hostname)" --acceptTeeEula
   ```

4. **Network for stage B** (jobs B1 and B2): outbound HTTPS to `github.com`,
   `objects.githubusercontent.com` and `release-assets.githubusercontent.com` (Grype's
   release), and `grype.anchore.io` (its vulnerability database). PSGallery is contacted only if
   a bundled tool is missing. Without internet access, stage A still works: set
   `runSupplyChain: false` in step 3.
5. **Behind a web proxy:** the proxy you give the agent (`--proxyurl`) is not passed to the
   scripts. Add it to the `.env` file in the agent's folder, then restart the agent:

   ```
   HTTPS_PROXY=http://proxy.example.local:8080
   NO_PROXY=<server>
   ```

   If the proxy inspects TLS, add its CA to the machine's trust store.
6. **Use single-use agents.** Job A3 runs the repository's own Pester tests, which means the
   code of the branch being built. On a machine that is reused, that code can change what the
   next jobs run (the agent user's git configuration, PowerShell modules, the agent's cached
   tasks), and so make the security analysis of a later build pass. Run each job on a fresh
   agent: for example, a container that starts the agent with `./run.sh --once` and is
   recreated after each job. If you cannot, set `runPester: false` in step 3 so that no code of
   the branch runs.

---

## 1. Bring the template repository in

Do this once per organization (Services) or collection (Server).

1. **Create an empty repository:** *Repos > New repository*, name `TemplatePipeline`, with no
   README and no `.gitignore`, so that it has no commit yet.
2. **Copy the template with its history and tags**, from a machine that can reach both the
   source and your organization or collection:

   ```bash
   git clone --bare <source-url-of-TemplatePipeline> TemplatePipeline.git
   cd TemplatePipeline.git
   # Services: https://dev.azure.com/<organization>/<project>/_git/TemplatePipeline
   # Server:   https://<server>/<collection>/<project>/_git/TemplatePipeline
   git push --mirror <your-new-repository-url>
   ```

   A bare clone holds only branches and tags, so `--mirror` pushes `main`, `dev` and every
   release tag (`v1.0.0` ...). Check the tags under *Repos > Tags*.
3. **Default branch:** *Repos > Branches*, on `main` choose *... > Set as default branch*.

Never edit the copy's files in the web editor for a release: a release is a tag (step 2).

**In a subfolder of another repository instead** (for example `e2e/powershell`): copy the
template's files there, and in `pwsh-ci.yml` change the `ciToolsRoot` parameter's default
**and** its single allowed value together, to `$(Pipeline.Workspace)/ci-tools/e2e/powershell`.
Pipelines then extend `e2e/powershell/pwsh-ci.yml@TemplatePipeline`, and the Required template
check (step 4) names that path. Before choosing this, weigh what sharing a repository changes:
- everyone who can push to that repository's `main` can change the scanner, its rules and its
  allow-list, unless a path-scoped branch policy requires reviewers on `e2e/powershell/*`;
- a tag versions the whole repository: the template's releases are tied to the other folders,
  and a prefix such as `powershell/v1.7.0` keeps their tags apart;
- every job checks out the whole repository;
- if that repository is itself built with this template, its scan also covers the bundled tools
  under `e2e/powershell/internal-ci/` (only a root `internal-ci/` is skipped).

---

## 2. Protect the template and publish a release

A pipeline that uses the template pins one of its tags. Anyone who can move a tag or push to
`main` controls what every pipeline runs, so protect both.

### 2.1 Protect `main`

*Project settings > Repositories > TemplatePipeline > Policies > Branch policies* on `main`:
require a minimum number of reviewers (at least 1) and, if you like, a linked work item. Changes
then reach `main` only through a pull request from `dev`.

### 2.2 Protect the tags

*Project settings > Repositories > TemplatePipeline > Security*:

- **Create tag:** allow it only to the maintainers of the template (for example a
  `TemplatePipeline Maintainers` group), and remove it from *Contributors*. Whoever creates a
  tag gets **Force push** on that tag by default, and Force push lets a tag be deleted and
  recreated on another commit.
- **Force push (rewrite history, delete branches and tags):** deny it to everyone but the
  maintainers. No group has it by default; check that nobody was given it.

### 2.3 Publish a release

Releases are annotated tags on `main`, named `vMAJOR.MINOR.PATCH`:
- PATCH (`v1.6.4`): a fix, same parameters;
- MINOR (`v1.7.0`): a new feature or parameter, existing pipelines unchanged;
- MAJOR (`v2.0.0`): an extending pipeline must change.

```bash
git checkout dev
# ... changes, checked locally ...
git push origin dev
# merge dev into main (a pull request when main has a branch policy), then:
git checkout main
git pull
git tag -a v1.7.0 -m "v1.7.0 - <one-line summary>

<what changes for an extending pipeline, and what was checked>"
git push origin v1.7.0
```

The tag message is the release note. **Never move or delete a pushed tag**: a pipeline that
pins it would silently run something else. A fix is a new tag.

---

## 3. Create a PowerShell repository that uses the template

### 3.1 The repository

1. *Repos > New repository*, for example `MyModule`, in any project of the same organization
   or collection (on Server, the two repositories **must** be in the same collection).
2. Add your code and a Pester test folder, for example:

   ```
   MyModule/
     MyModule.psd1
     MyModule.psm1
     Tests/
       MyModule.Tests.ps1
     azure-pipelines.yml
   ```

### 3.2 The pipeline file

`azure-pipelines.yml` at the root of the repository:

```yaml
trigger:
  batch: true
  branches:
    include:
    - '*'

resources:
  repositories:
  - repository: TemplatePipeline   # the alias the template checks out: keep it
    type: git
    name: LABIA/TemplatePipeline   # <project>/<repository> of step 1
    ref: refs/tags/v1.7.0          # a release tag of step 2

extends:
  template: pwsh-ci.yml@TemplatePipeline
  parameters:
    baseBranch: main       # default: the branch every change is compared to
    testPath: Tests        # default: the Pester test folder
    runPester: true        # default: job A3, the repository's tests
    runSupplyChain: true   # default: stage B, the SBOM and the known-vulnerability check
    # Azure DevOps Server only (or a self-hosted pool on Services):
    # poolName: pwsh-ci
```

| Parameter | Default | Purpose |
| --- | --- | --- |
| `baseBranch` | `main` | Every commit since the branch left it is analysed. Stage A is skipped on it; stage B runs on it too. |
| `testPath` | `Tests` | The Pester test folder, relative to the repository root. |
| `securityExceptionsFile` | empty | Job A1's false-positive exceptions, read from the base branch only; empty, `.security/a1-exceptions.json` (step 3.3). |
| `runPester` | `true` | Job A3. `false` runs no code of the branch. |
| `runSupplyChain` | `true` | Stage B: SBOM (B1) and known vulnerabilities (B2). Needs internet access. |
| `vmImage` | `ubuntu-latest` | The Microsoft-hosted image, used when `poolName` is empty (Services only). |
| `poolName` | empty | A self-hosted pool. Required on Azure DevOps Server. |
| `dependencyTrackVariableGroup` | empty | Job B3: publishes the SBOM to Dependency-Track on base-branch builds (step 3.6). |
| `dependencyTrackProjectName` | empty | B3's project in Dependency-Track; empty, the repository's name. |

### 3.3 Accepted vulnerabilities and A1 false positives (optional)

Job B2 fails on a High or Critical vulnerability that has a fix. To accept one for a while, add
`.supplychain/cve-exceptions.json`:

```json
{ "exceptions": [ { "id": "GHSA-5crp-9r3c-p9vr", "package": "Newtonsoft.Json", "reason": "Input depth is limited by the caller.", "expires": "2027-03-31" } ] }
```

Each entry names one vulnerability and one package, with a reason and an expiry at most a year
ahead. An invalid or expired entry fails the job. The file is in your repository, so a branch
can add an entry: protect it with your branch policy (step 3.5).

**A false positive of job A1** (it needs `v1.6.3` or later): add
`.security/a1-exceptions.json` (or the file `securityExceptionsFile` names) **to `main` first**,
in its own pull request:

```json
{ "exceptions": [ { "rule": "Encoded command", "file": "src/Build.ps1", "sha256": "<the file's SHA-256>", "reason": "Test fixture: the string is never run.", "expires": "2027-03-31" } ] }
```

Each entry names one A1 rule (the rule name A1 reports), one file by its path from the
repository root, and that file's SHA-256 (`Get-FileHash -Algorithm SHA256 <file>`), with a
reason and an expiry at most a year ahead. A1 reads the file from the base branch only, never
from the branch it tests, so a branch cannot excuse its own findings: merge the exception,
then the change it excuses. The Error findings of that rule in that file become warnings that
show the reason, as long as the file keeps that hash; an edit of the file asks for a new
exception. An invalid or expired entry fails A1. A file that does not parse, and the encoding
check, cannot be excepted.

Only this file accepts a finding. A `SuppressMessageAttribute` in the analysed file does not: since
`v1.7.0`, A1 counts that finding anyway, with its severity, and logs it as
`Suppressed in the file, still counted`. A branch with such an attribute on an A1 rule can start
failing when its `ref` moves to that release.

### 3.4 Create and run the pipeline

1. Commit and push to `main`.
2. *Pipelines > New pipeline > Azure Repos Git > MyModule > Existing Azure Pipelines YAML file*,
   path `/azure-pipelines.yml`, then *Run*.
3. **The first run waits for authorization** to read `TemplatePipeline` (and, on Server, to use
   the pool): open the run, choose *View > Permit*. This happens once per pipeline.
4. On `main` (the base branch), only stage B runs. Push a branch with a change to a `.ps1`
   file: stage A runs A1, A2, then A3, next to stage B.

**If the template repository is in another project** and *Limit job authorization scope to
current project* is on (*Project settings > Pipelines > Settings*; on by default for new
projects), the checkout of `TemplatePipeline` fails with `TF401019`. Give the build identity of
the pipeline's project, `<Project> Build Service (<organization or collection>)`, **Read** on
the `TemplatePipeline` repository (*Project settings > Repositories > TemplatePipeline >
Security*). Keeping both repositories in the same project avoids this.

### 3.5 Protect the repository's own `main`

*Project settings > Repositories > MyModule > Policies > Branch policies* on `main`: require
reviewers, and add a **Build validation** policy with this pipeline, so that a pull request
merges only when the pipeline passes.

### 3.6 Publish the SBOM to Dependency-Track (optional)

Job B3 sends the SBOM of each `main` build to Dependency-Track (5.x, or 4.11.4 or later). It
needs `v1.5.0` or later.

1. **In Dependency-Track** (*Administration > Access Management > Teams*): create a team, for
   example `azure-pipelines`, with the permissions `BOM_UPLOAD` and `PROJECT_CREATION_UPLOAD`
   only, and copy its API key.
2. **The network:** the agents must reach the Dependency-Track API server over `https`. On
   Microsoft-hosted agents, that server must be reachable from the internet; on self-hosted
   agents, add it to `NO_PROXY` when it is internal (step 0), and its CA to the trust store.
3. **The variable group** (*Pipelines > Library > + Variable group*), for example
   `dependency-track`:
   - `DependencyTrackUrl` = `https://dtrack.example.com` (the API server, without `/api`);
   - `DependencyTrackApiKey` = the key, with the lock icon (**secret**).

   Leave *Allow access to all pipelines* off.
4. **Protect the group** (*Library > dependency-track > Approvals and checks*):
   - **Branch control**: allowed branches `refs/heads/main`, and *Verify branch protection*
     on;
   - **Required template**: *Azure Repos*, `LABIA/TemplatePipeline`, the release tag
     (`refs/tags/v1.7.0`), `pwsh-ci.yml`. Update its *Ref* at each release, as in step 4.
5. **The pipeline** (`azure-pipelines.yml`, through a pull request):

   ```yaml
   extends:
     template: pwsh-ci.yml@TemplatePipeline
     parameters:
       dependencyTrackVariableGroup: dependency-track
       # dependencyTrackProjectName: MyModule   # default: the repository's name
   ```

6. **The first `main` build** waits for permission to use the group: *View > Permit*. B3 then
   creates the project `MyModule`, version `main`, tagged with the Azure DevOps project.

Never put the URL or the key in `azure-pipelines.yml`: a branch could change the URL to a
server that receives the key. Branch builds don't run B3 and never get the key.

### 3.7 Publish the module to a NuGet feed (optional)

Jobs C1 and C2 pack the repository's PowerShell module into a `.nupkg` on every build and push
it to an Azure Artifacts feed on tag builds only: the tag is the release. C1 packs with the bundled PSResourceGet;
C2 pushes with `dotnet nuget push`, so the agent needs the .NET SDK (the Microsoft-hosted
images have it; step 0 for a self-hosted agent). It needs `v1.6.2` or later, and `v1.6.3` is the release to use: every earlier one lets a value passed to the template run as code in its jobs (C1 of `v1.6.0` and `v1.6.1` fails on Linux agents; `v1.6.0` also pushes on `main` builds, and its stage C does not wait for stage A).

1. **The feed** (*Artifacts > Create feed*), for example `powershell-modules`: any visibility
   works; upstream sources are not needed. Copy its URL from the *Connect to feed* pane (the
   NuGet v3 one, ending in `/nuget/v3/index.json`).
2. **The build identity's grant** (*Artifacts > the feed > Settings > Permissions > Add
   users/groups*): the pipeline runs as the *build service account* — `<project> Build Service
   (<org>)`, or the collection-scoped *Project Collection Build Service* when the project
   allows it. Give it the **Feed Publisher** role on this feed, and on no other feed you do not
   mean to publish to: the identity can push only where it holds that role. That grant is the
   whole credential — the `NuGetAuthenticate` task uses the build identity's own token, so
   there is no PAT and nothing to rotate.
3. **The pipeline** (`azure-pipelines.yml`, through a pull request): a tag trigger (without
   it, pushing a tag starts no build and nothing is published) and the parameters.
   `publishFeed` is required: C1 checks it on every build (set, `https`), so a missing one fails
   the pull request.

   ```yaml
   trigger:
     batch: true
     branches:
       include:
       - '*'
     tags:
       include:
       - 'v*'   # your release tag pattern

   extends:
     template: pwsh-ci.yml@TemplatePipeline
     parameters:
       publishPackage: true
       publishFeed: 'https://pkgs.dev.azure.com/<org>/<project>/_packaging/<feed>/nuget/v3/index.json'
       # packageSpec: 'src/MyModule/MyModule.psd1'   # default: the single .psd1 at the repository root
   ```

4. **A feed outside the organization** instead: a NuGet service connection (*Project settings >
   Service connections > New service connection > NuGet*, the feed's URL and a PAT with
   *Packaging > Read & write*, as a username/password or token connection), its name in
   `publishServiceConnection`, and on the connection the same two checks as the variable group
   in step 3.6, except that Branch control allows your release tags (`refs/tags/v*`), not
   `refs/heads/main`: C2 runs only on tag builds. An API-key connection does not work
   (`NuGetAuthenticate` does not take one), so nuget.org and PSGallery are out of reach.

The version published is the manifest's `ModuleVersion`, and the feed refuses a version already
there: releasing is bumping the manifest, merging, then tagging that commit, never overwriting.
Branch and `main` builds pack but never push (a `main` push would make the tag's push fail on
the duplicate); the push runs only on tag builds, after stages A and B succeeded. Creating a
tag is what publishes: limit who can create tags in the repository, as step 2.2 does for the
template. Name the tag after the version (`v1.2.3`, or `release/1.2.3`): when the tag's
version (after its last `/`, without a leading `v`) differs from the manifest's, C1 shows a
warning in the build summary, and the package is still published under the manifest's
version.

---

## 4. Enforce the template

Without enforcement, a branch can edit its `azure-pipelines.yml` to stop extending the template,
or pin another ref. The **Required template** check closes that: a stage that uses a protected
resource starts only if the pipeline extends the given template, at the given ref.

1. Pick a protected resource that every run uses:
   - the **repository under test** (*Project settings > Repositories > MyModule > ... >
     Approvals and checks*), or
   - the **agent pool** (*Project settings > Agent pools > pwsh-ci > Approvals and checks*),
     the natural choice on Azure DevOps Server.
2. *Add check > Required template*:
   - Repository type: *Azure Repos*;
   - Repository: `LABIA/TemplatePipeline`;
   - Ref: `refs/tags/v1.7.0`;
   - Path to required template: `pwsh-ci.yml`.
3. **Test it:** push a branch whose `azure-pipelines.yml` runs a plain script instead of
   `extends`; its run must fail on the check. Then delete the branch.

Update the check's *Ref* at each release (step 5).

---

## 5. Take a new release

In this order, so that no build pins a missing tag:

1. The template's maintainers publish the tag (step 2.3).
2. In each repository, change `ref: refs/tags/<new tag>` in `azure-pipelines.yml`, through a
   pull request.
3. Update the Required template check's *Ref* to the new tag (step 4). A check on the old tag
   fails every pipeline that moved; a check on the new tag fails those that did not.

A pipeline gets the new release, including new security rules, only when its `ref` moves.

---

## Troubleshooting

| Symptom | Cause and fix |
| --- | --- |
| On Server, the run fails before any job: no pool, or no `Azure Pipelines` pool for `vmImage` | Set `poolName` to your self-hosted pool (step 0). |
| A job waits with *This pipeline needs permission to access a resource* | Authorize it on the run page (step 3.4). |
| `TF401019` when checking out `TemplatePipeline` | The job authorization scope (step 3.4), or the repository name in `resources`. |
| The run fails at once: the ref cannot be resolved | The tag in `ref` does not exist in your copy: push it (step 1.2) or fix the name. |
| *Required template* check fails | The pipeline's `ref` and the check's *Ref* differ (step 5). |
| A1, A2 or A3 stops: missing `origin/main`, or shallow clone | `baseBranch` names a branch that does not exist, or the history is incomplete. The template fetches the full history itself; check `baseBranch`. |
| A3: *Unable to find type [PesterConfiguration]* | The agent's PowerShell is older than 7.4 (step 0). |
| B2 cannot download Grype or its database | No internet access or a proxy (step 0, items 4 and 5). Without access, set `runSupplyChain: false`. |
| B2 fails on a vulnerability | Update the package to a fixed version, or accept it for a while (step 3.3). |
| B3: `DEPENDENCYTRACK_URL` or `DEPENDENCYTRACK_APIKEY is not set` | The group lacks `DependencyTrackUrl` or `DependencyTrackApiKey`, or another group is named (step 3.6). |
| B3: HTTP 401 or 403 | The key is wrong, or its team lacks `BOM_UPLOAD` or `PROJECT_CREATION_UPLOAD`. |
| B3: HTTP 400 | Dependency-Track rejected the SBOM; its message is in B3's log (artifact `tec-pwsh-sbom-publish-failure-log`). |
| B3: no answer, or did not finish processing | The server is unreachable from the agent (step 3.6, item 2), or overloaded. |
| Stage B waits or fails on the variable group's checks | The Branch control or Required template check: the build is not on `main`, or does not extend the template at the checked tag. |

Each failed job publishes its logs as a build artifact (`*-failure-log`), and B2 always
publishes `sec-pwsh-cve-report`. Findings and failed tests also show in the build summary, at
their file and line.
