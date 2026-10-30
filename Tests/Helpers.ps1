#Requires -Version 7.4
<#
.SYNOPSIS
Shared fixtures and helpers for the TemplatePipeline test suite.
.DESCRIPTION
Dot-source this file from a *.Tests.ps1 BeforeAll block. The helpers build agent-like
layouts under the machine temporary folder: git repositories with a base branch reference,
ci-tools copies of the job scripts (never the working tree), and process invocations of
the scripts with a controlled environment. Nothing is written into the repository.
#>

$script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$script:ScratchRoot = Join-Path ([IO.Path]::GetTempPath()) ('templatepipeline-tests-' + [Environment]::UserName)

# Environment variables the job scripts read: cleared around every invocation, so a test
# cannot inherit a value from the runner's shell.
$script:JobEnvironmentVariables = @(
    'TF_BUILD', 'BUILD_REASON', 'BUILD_SOURCEVERSION', 'BUILD_SOURCESDIRECTORY',
    'BUILD_REPOSITORY_NAME', 'BUILD_REQUESTEDFOR', 'BUILD_SOURCEBRANCH',
    'AGENT_TEMPDIRECTORY', 'TEMPLATE_REF',
    'DEPENDENCYTRACK_URL', 'DEPENDENCYTRACK_APIKEY', 'DEPENDENCYTRACK_PROJECT_NAME',
    'DEPENDENCYTRACK_PROJECT_VERSION', 'DEPENDENCYTRACK_PROJECT_TAG',
    'GRYPE_DB_UPDATE_URL', 'GRYPE_DB_VALIDATE_AGE'
)

function New-ScratchDirectory {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
    param([Parameter(Mandatory = $true)][string]$Name)
    if (-not (Test-Path -LiteralPath $script:ScratchRoot)) {
        New-Item -ItemType Directory -Path $script:ScratchRoot | Out-Null
    }
    $path = Join-Path $script:ScratchRoot ($Name + '-' + (Get-Date).Ticks)
    New-Item -ItemType Directory -Path $path | Out-Null
    return $path
}

function Remove-Scratch {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
    param([Parameter(Mandatory = $true)][string]$Path)
    if (Test-Path -LiteralPath $Path) {
        Remove-Item -LiteralPath $Path -Recurse -Force
    }
}

function Invoke-Git {
    param(
        [Parameter(Mandatory = $true)][string]$Repository,
        [Parameter(Mandatory = $true)][string[]]$Arguments
    )
    $output = & git -C $Repository @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "git $($Arguments -join ' ') failed (exit $LASTEXITCODE): $(@($output) -join ' ')"
    }
    return $output
}

function New-GitRepository {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
    param([Parameter(Mandatory = $true)][string]$Name)
    $repo = New-ScratchDirectory -Name $Name
    Invoke-Git -Repository $repo -Arguments @('init') | Out-Null
    Invoke-Git -Repository $repo -Arguments @('symbolic-ref', 'HEAD', 'refs/heads/main') | Out-Null
    Invoke-Git -Repository $repo -Arguments @('config', 'user.email', 'tests@templatepipeline.local') | Out-Null
    Invoke-Git -Repository $repo -Arguments @('config', 'user.name', 'TemplatePipeline Tests') | Out-Null
    return $repo
}

function Add-GitCommit {
    param(
        [Parameter(Mandatory = $true)][string]$Repository,
        [Parameter(Mandatory = $true)][string]$Message
    )
    Invoke-Git -Repository $Repository -Arguments @('add', '-A') | Out-Null
    Invoke-Git -Repository $Repository -Arguments @('commit', '-m', $Message) | Out-Null
}

# A repository with one commit on main, a 'work' branch with the given files on top, and a
# local refs/remotes/origin/main pointing at the base commit: the analysis range of the
# scripts, without a real remote.
function New-AnalysisRepository {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][hashtable]$ChangedFiles,
        [string]$BaseContent = '# base'
    )
    $repo = New-GitRepository -Name $Name
    Set-Content -LiteralPath (Join-Path $repo 'README.md') -Value $BaseContent -NoNewline
    Add-GitCommit -Repository $repo -Message 'base'
    $baseCommit = @(Invoke-Git -Repository $repo -Arguments @('rev-parse', 'HEAD'))[0]
    Invoke-Git -Repository $repo -Arguments @('checkout', '-b', 'work') | Out-Null
    foreach ($key in $ChangedFiles.Keys) {
        $target = Join-Path $repo $key
        New-Item -ItemType Directory -Path (Split-Path -Parent $target) -Force | Out-Null
        Set-Content -LiteralPath $target -Value $ChangedFiles[$key] -NoNewline
    }
    Add-GitCommit -Repository $repo -Message 'change'
    Invoke-Git -Repository $repo -Arguments @('update-ref', 'refs/remotes/origin/main', $baseCommit) | Out-Null
    return $repo
}

# A git repository holding a module manifest (.psd1) and its root module, for B1 and C1.
function New-ModuleRepository {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [string]$ManifestRelativePath = 'TestModule.psd1',
        [string]$ModuleName = 'TestModule',
        [string]$Version = '1.0.0',
        [string]$ExtraContent = '',
        [hashtable]$ExtraFiles = @{}
    )
    $repo = New-GitRepository -Name $Name
    $manifestFolder = Split-Path -Parent (Join-Path $repo $ManifestRelativePath)
    if ($manifestFolder -and -not (Test-Path -LiteralPath $manifestFolder)) {
        New-Item -ItemType Directory -Path $manifestFolder -Force | Out-Null
    }
    $moduleFile = [IO.Path]::GetFileNameWithoutExtension($ManifestRelativePath) + '.psm1'
    $manifest = "@{`n    RootModule = '$moduleFile'`n    ModuleVersion = '$Version'`n    GUID = '$([guid]::NewGuid().ToString())'`n    Author = 'tests'`n    CompanyName = 'tests'`n    Description = 'test fixture'$ExtraContent`n    FunctionsToExport = '*'`n}"
    Set-Content -LiteralPath (Join-Path $repo $ManifestRelativePath) -Value $manifest -NoNewline
    Set-Content -LiteralPath (Join-Path $repo ([IO.Path]::Combine((Split-Path -Parent $ManifestRelativePath), $moduleFile))) -Value "function Get-$ModuleName { 'fixture' }" -NoNewline
    foreach ($key in $ExtraFiles.Keys) {
        $target = Join-Path $repo $key
        New-Item -ItemType Directory -Path (Split-Path -Parent $target) -Force | Out-Null
        Set-Content -LiteralPath $target -Value $ExtraFiles[$key] -NoNewline
    }
    Add-GitCommit -Repository $repo -Message 'module'
    $commit = @(Invoke-Git -Repository $repo -Arguments @('rev-parse', 'HEAD'))[0]
    Invoke-Git -Repository $repo -Arguments @('update-ref', 'refs/remotes/origin/main', $commit) | Out-Null
    return $repo
}

# A ci-tools folder, like the pipeline's checkout of this repository: the shared file, the
# job scripts under test, and (with -WithTools) the bundled internal-ci tools.
function New-CiToolsCopy {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string[]]$Scripts,
        [switch]$WithTools
    )
    $tools = New-ScratchDirectory -Name $Name
    Copy-Item -LiteralPath (Join-Path $script:RepoRoot 'pwsh-ci-common.ps1') -Destination $tools
    foreach ($s in $Scripts) {
        Copy-Item -LiteralPath (Join-Path $script:RepoRoot $s) -Destination $tools
    }
    if ($WithTools) {
        Copy-Item -LiteralPath (Join-Path $script:RepoRoot 'internal-ci') -Destination $tools -Recurse
    }
    return $tools
}

# Runs a job script of the template in a child pwsh (or Windows PowerShell), the way the
# pipeline tasks do. The job environment variables are cleared first; -Environment sets the
# ones the case needs. The child works in the repository folder. Returns exit code and the
# console output as one string.
function Invoke-JobScript {
    param(
        [Parameter(Mandatory = $true)][string]$CiTools,
        [Parameter(Mandatory = $true)][string]$ScriptName,
        [string]$RepositoryPath = '',
        [hashtable]$Arguments = @{},
        [hashtable]$Environment = @{},
        [switch]$UseWindowsPowerShell,
        [switch]$WithoutDotnet
    )
    $argList = @('-NoProfile', '-File', (Join-Path $CiTools $ScriptName))
    if ($RepositoryPath) {
        $argList += @('-RepositoryPath', $RepositoryPath)
    }
    foreach ($key in $Arguments.Keys) {
        $argList += @("-$key", [string]$Arguments[$key])
    }

    $names = @($script:JobEnvironmentVariables + $Environment.Keys | Select-Object -Unique)
    $saved = @{}
    foreach ($name in $names) {
        $saved[$name] = [Environment]::GetEnvironmentVariable($name)
        [Environment]::SetEnvironmentVariable($name, $null)
    }
    $savedPath = $env:PATH
    $savedModulePath = $env:PSModulePath
    try {
        foreach ($key in $Environment.Keys) {
            [Environment]::SetEnvironmentVariable($key, [string]$Environment[$key])
        }
        $hostExe = 'pwsh'
        if ($UseWindowsPowerShell) {
            $hostExe = 'powershell.exe'
            $env:PSModulePath = (Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'WindowsPowerShell\Modules') + [IO.Path]::PathSeparator + [Environment]::GetEnvironmentVariable('PSModulePath', 'Machine')
        }
        if ($WithoutDotnet) {
            $dotnet = Get-Command dotnet -ErrorAction SilentlyContinue
            if ($dotnet) {
                $dotnetDir = (Split-Path -Parent $dotnet.Source).TrimEnd('\', '/')
                $env:PATH = (@($env:PATH -split [IO.Path]::PathSeparator | Where-Object { $_ -and $_.TrimEnd('\', '/') -ne $dotnetDir }) -join [IO.Path]::PathSeparator)
            }
        }
        $output = & $hostExe @argList 2>&1 | Out-String
        return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = $output }
    } finally {
        foreach ($name in $names) {
            [Environment]::SetEnvironmentVariable($name, $saved[$name])
        }
        $env:PATH = $savedPath
        $env:PSModulePath = $savedModulePath
    }
}

# The log files a ci-tools copy produced (sorted by write time), or their content with -Raw.
function Get-CiLog {
    param(
        [Parameter(Mandatory = $true)][string]$CiTools,
        [switch]$Raw
    )
    $logDir = Join-Path $CiTools 'Logs'
    if (-not (Test-Path -LiteralPath $logDir)) {
        return @()
    }
    $logs = @(Get-ChildItem -LiteralPath $logDir -Filter '*.log' | Sort-Object LastWriteTime)
    if ($Raw) {
        return @($logs | ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw })
    }
    return $logs
}

# The A1 attack sample, taken as data at run time (never committed into a .ps1 of this
# repository, per the project's directive).
function Get-AttackSample {
    return (Get-Content -LiteralPath (Join-Path $script:RepoRoot (Join-Path 'internal-ci' (Join-Path 'Samples' 'BaselineSample.txt'))) -Raw)
}

# The entry names of a .nupkg (read only), for content assertions.
function Get-NupkgEntry {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [string]$Filter = '*'
    )
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [IO.Compression.ZipFile]::OpenRead($Path)
    try {
        return @($zip.Entries | Where-Object { $_.FullName -like $Filter } | ForEach-Object { $_.FullName })
    } finally {
        $zip.Dispose()
    }
}

# True when the machine can reach the internet (the Grype host), false otherwise.
# True when both hosts Grype needs answer: its GitHub release (the binary) and the
# Anchore database host (the listing). A machine behind a flaky proxy reports offline
# and the Network-tagged tests skip instead of failing on a transient error.
function Test-Online {
    $urls = @(
        'https://github.com/anchore/grype/releases',
        'https://grype.anchore.io/databases/listing.json'
    )
    foreach ($url in $urls) {
        try {
            $response = Invoke-WebRequest -Uri $url -Method Head -TimeoutSec 10 -SkipHttpErrorCheck
            if ($response.StatusCode -ge 500) {
                return $false
            }
        } catch {
            return $false
        }
    }
    return $true
}

# True when the current user and file system allow creating a symbolic link.
function Test-SymlinkSupport {
    $probe = New-ScratchDirectory -Name 'symlink-probe'
    try {
        Set-Content -LiteralPath (Join-Path $probe 'target.txt') -Value 'x' -NoNewline
        New-Item -ItemType SymbolicLink -Path (Join-Path $probe 'link.txt') -Target (Join-Path $probe 'target.txt') -ErrorAction Stop | Out-Null
        return $true
    } catch {
        return $false
    } finally {
        Remove-Scratch -Path $probe
    }
}

# Runs C1 (tec-pwsh-package-pack.ps1) and collects its result plus the single .nupkg the
# job copied next to its log (in the ci-tools copy's Logs folder).
function Invoke-PackResult {
    param(
        [Parameter(Mandatory = $true)][string]$CiTools,
        [Parameter(Mandatory = $true)][string]$RepositoryPath,
        [hashtable]$Arguments = @{},
        [string]$PublishFeed = 'https://pkgs.dev.azure.com/example/example/_packaging/tests/nuget/v3/index.json',
        [switch]$UseWindowsPowerShell
    )

    # A previous run of this ci-tools copy may have left a package next to its log: only
    # the package this run produces may be collected.
    $logDir = Join-Path $CiTools 'Logs'
    if (Test-Path -LiteralPath $logDir) {
        Get-ChildItem -LiteralPath $logDir -Filter '*.nupkg' | Remove-Item -Force
    }

    $result = Invoke-JobScript -CiTools $CiTools -ScriptName 'tec-pwsh-package-pack.ps1' `
        -RepositoryPath $RepositoryPath -Arguments (@{ PublishFeed = $PublishFeed } + $Arguments) -UseWindowsPowerShell:$UseWindowsPowerShell
    $nupkg = @(Get-ChildItem -LiteralPath $logDir -Filter '*.nupkg' -ErrorAction SilentlyContinue)
    [pscustomobject]@{
        ExitCode = $result.ExitCode
        Output   = $result.Output
        Nupkg    = if ($nupkg.Count -eq 1) { $nupkg[0].FullName } else { $null }
    }
}

# A folder holding Count copies of the given .nupkg, like the downloaded pub-pwsh-package
# artifact C2 pushes.
function New-NupkgFolder {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
    param(
        [Parameter(Mandatory = $true)][string]$SourceNupkg,
        [Parameter(Mandatory = $true)][string]$Name,
        [int]$Count = 1
    )
    $folder = New-ScratchDirectory -Name $Name
    $leaf = Split-Path -Leaf $SourceNupkg
    for ($i = 1; $i -le $Count; $i++) {
        $target = if ($i -eq 1) { $leaf } else { ($leaf -replace '\.nupkg$', '') + "-$i.nupkg" }
        Copy-Item -LiteralPath $SourceNupkg -Destination (Join-Path $folder $target)
    }
    return $folder
}

# Runs C2 (pub-pwsh-package-push.ps1) against a package folder.
function Invoke-PushResult {
    param(
        [Parameter(Mandatory = $true)][string]$CiTools,
        [Parameter(Mandatory = $true)][string]$PackageFolder,
        [string]$PublishFeed = 'https://pkgs.dev.azure.com/example/example/_packaging/tests/nuget/v3/index.json',
        [switch]$WithoutDotnet
    )
    return Invoke-JobScript -CiTools $CiTools -ScriptName 'pub-pwsh-package-push.ps1' `
        -Arguments @{ PackageFolder = $PackageFolder; PublishFeed = $PublishFeed } -WithoutDotnet:$WithoutDotnet
}

# Runs B3 (tec-pwsh-sbom-publish.ps1) against an SBOM file with the given environment.
function Invoke-PublishResult {
    param(
        [Parameter(Mandatory = $true)][string]$CiTools,
        [Parameter(Mandatory = $true)][string]$SbomPath,
        [Parameter(Mandatory = $true)][hashtable]$Environment,
        [hashtable]$Set = @{}
    )

    # The pipeline always defines the repository's name; the job's project-name fallback
    # resolves it when DEPENDENCYTRACK_PROJECT_NAME is empty. -Set overrides entries of
    # -Environment without the duplicate-key error of hashtable addition.
    $merged = @{}
    foreach ($key in $Environment.Keys) {
        $merged[$key] = $Environment[$key]
    }
    if (-not $merged.ContainsKey('BUILD_REPOSITORY_NAME')) {
        $merged['BUILD_REPOSITORY_NAME'] = 'Tests'
    }
    foreach ($key in $Set.Keys) {
        $merged[$key] = $Set[$key]
    }
    return Invoke-JobScript -CiTools $CiTools -ScriptName 'tec-pwsh-sbom-publish.ps1' `
        -Arguments @{ SbomPath = $SbomPath } -Environment $merged
}

# Runs an analysis job script (A1 or A2) against a repository.
function Invoke-AnalysisResult {
    param(
        [Parameter(Mandatory = $true)][string]$CiTools,
        [Parameter(Mandatory = $true)][string]$ScriptName,
        [Parameter(Mandatory = $true)][string]$RepositoryPath,
        [hashtable]$Arguments = @{},
        [hashtable]$Environment = @{},
        [switch]$UseWindowsPowerShell
    )
    return Invoke-JobScript -CiTools $CiTools -ScriptName $ScriptName -RepositoryPath $RepositoryPath `
        -Arguments $Arguments -Environment $Environment -UseWindowsPowerShell:$UseWindowsPowerShell
}

# Runs A3 (biz-pwsh-analysis-pester.ps1) against a repository.
function Invoke-PesterJobResult {
    param(
        [Parameter(Mandatory = $true)][string]$CiTools,
        [Parameter(Mandatory = $true)][string]$RepositoryPath,
        [hashtable]$Arguments = @{},
        [hashtable]$Environment = @{},
        [switch]$UseWindowsPowerShell
    )
    return Invoke-JobScript -CiTools $CiTools -ScriptName 'biz-pwsh-analysis-pester.ps1' -RepositoryPath $RepositoryPath `
        -Arguments $Arguments -Environment $Environment -UseWindowsPowerShell:$UseWindowsPowerShell
}

# Runs B2 (sec-pwsh-analysis-cve.ps1) against a repository and an SBOM file.
function Invoke-CveResult {
    param(
        [Parameter(Mandatory = $true)][string]$CiTools,
        [Parameter(Mandatory = $true)][string]$SbomPath,
        [Parameter(Mandatory = $true)][string]$RepositoryPath,
        [hashtable]$Arguments = @{},
        [hashtable]$Environment = @{}
    )
    return Invoke-JobScript -CiTools $CiTools -ScriptName 'sec-pwsh-analysis-cve.ps1' `
        -RepositoryPath $RepositoryPath -Arguments (@{ SbomPath = $SbomPath } + $Arguments) -Environment $Environment
}

# Runs B2 again when the first failure looks like the transient Grype listing/download
# error seen through flaky proxies ("unable to download listing: relative paths require a
# module with a pwd"), which is grype's misleading name for a failed listing fetch.
function Invoke-CveResultResilient {
    param(
        [Parameter(Mandatory = $true)][string]$CiTools,
        [Parameter(Mandatory = $true)][string]$SbomPath,
        [Parameter(Mandatory = $true)][string]$RepositoryPath,
        [hashtable]$Arguments = @{},
        [hashtable]$Environment = @{}
    )

    # The listing host behind a flaky proxy fails often and briefly; grype then reports
    # "unable to download listing: relative paths require a module with a pwd", its
    # misleading name for that fetch failing. Retry the run up to three times, with a
    # growing pause, before letting the failure stand.
    $delays = @(0, 15, 30)
    $result = $null
    foreach ($delay in $delays) {
        if ($delay -gt 0) {
            Start-Sleep -Seconds $delay
        }
        $result = Invoke-CveResult -CiTools $CiTools -SbomPath $SbomPath -RepositoryPath $RepositoryPath -Arguments $Arguments -Environment $Environment
        if ($result.ExitCode -eq 0 -or $result.Output -notmatch 'unable to (download|update) vulnerability database|relative paths require a module with a pwd') {
            return $result
        }
    }
    return $result
}
