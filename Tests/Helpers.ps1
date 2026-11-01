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
        # Removed, not set to $null: PowerShell 7.5 and later (.NET 9) would leave it defined and
        # empty, and Grype then takes an empty GRYPE_DB_UPDATE_URL as its database's address.
        Remove-Item -LiteralPath "Env:$name" -ErrorAction SilentlyContinue
    }
    $savedPath = $env:PATH
    $savedModulePath = $env:PSModulePath
    try {
        foreach ($key in $Environment.Keys) {
            [Environment]::SetEnvironmentVariable($key, [string]$Environment[$key])
        }
        $hostName = 'pwsh'
        if ($UseWindowsPowerShell) {
            $hostName = 'powershell.exe'
            $env:PSModulePath = (Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'WindowsPowerShell\Modules') + [IO.Path]::PathSeparator + [Environment]::GetEnvironmentVariable('PSModulePath', 'Machine')
        }
        # Resolved before PATH changes: on Linux, dotnet and pwsh can share /usr/bin.
        $hostExe = @(Get-Command $hostName -CommandType Application)[0].Source
        if ($WithoutDotnet) {
            $dotnetDirs = @(Get-Command dotnet -All -CommandType Application -ErrorAction SilentlyContinue | ForEach-Object { (Split-Path -Parent $_.Source).TrimEnd('\', '/') })
            $env:PATH = (@($env:PATH -split [IO.Path]::PathSeparator | Where-Object { $_ -and $dotnetDirs -notcontains $_.TrimEnd('\', '/') }) -join [IO.Path]::PathSeparator)
        }
        $output = & $hostExe @argList 2>&1 | Out-String
        return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = $output }
    } finally {
        foreach ($name in $names) {
            Remove-Item -LiteralPath "Env:$name" -ErrorAction SilentlyContinue
            if ($null -ne $saved[$name]) {
                [Environment]::SetEnvironmentVariable($name, $saved[$name])
            }
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

# The findings the attack sample must raise, from BaselineFinding.txt (line|severity|rule|message).
function Get-BaselineFinding {
    $path = Join-Path $script:RepoRoot (Join-Path 'internal-ci' (Join-Path 'Samples' 'BaselineFinding.txt'))
    return @(Get-Content -LiteralPath $path | Where-Object { $_ } | ForEach-Object {
            $fields = $_ -split '\|', 4
            [pscustomobject]@{ Line = [int]$fields[0]; Severity = $fields[1]; RuleName = $fields[2] }
        })
}

# The one line of the attack sample on which the given Error rule fires, taken as data at run time.
function Get-AttackSampleLine {
    param([Parameter(Mandatory = $true)][string]$RuleName)
    $finding = @(Get-BaselineFinding | Where-Object { $_.RuleName -eq $RuleName -and $_.Severity -eq 'Error' })[0]
    return (Get-AttackSample) -split '\r?\n' | Select-Object -Index ($finding.Line - 1)
}

# How many real annotations of a type a job printed; a neutralized '##vso [' does not count.
function Get-AnnotationCount {
    param(
        [Parameter(Mandatory = $true)][string]$Output,
        [Parameter(Mandatory = $true)][ValidateSet('error', 'warning')][string]$Type,
        [string]$MessagePattern = ''
    )
    return ([regex]::Matches($Output, "##vso\[task\.logissue type=$Type[^\r\n]*$MessagePattern")).Count
}

# The console lines holding a ##vso[ other than the prefix of the job's own annotations.
function Get-ForeignLoggingCommand {
    param([Parameter(Mandatory = $true)][string]$Output)
    return @($Output -split '\r?\n' | Where-Object {
            $rest = if ($_.StartsWith('##vso[task.logissue ')) { $_.Substring('##vso['.Length) } else { $_ }
            $rest.Contains('##vso[')
        })
}

# Writes a wrapper into a ci-tools copy that does what PowerShell@2 does with a filePath task:
# dot-sources the script with the arguments as PowerShell text. Parameter values then come from
# the environment. -Prelude runs first, for a stand-in of a cmdlet. Returns the wrapper's name.
function New-TaskWrapper {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
    param(
        [Parameter(Mandatory = $true)][string]$CiTools,
        [Parameter(Mandatory = $true)][string]$ScriptName,
        [string]$Arguments = '',
        [string]$Prelude = ''
    )
    $text = "$Prelude`n. '$(Join-Path $CiTools $ScriptName)' $Arguments`nexit `$LASTEXITCODE`n"
    Set-Content -LiteralPath (Join-Path $CiTools 'task-wrapper.ps1') -Value $text
    return 'task-wrapper.ps1'
}

# The source of one function of a job script, taken from its AST, for the functions a job only
# reaches with a server or an agent's layout. The script itself is not run.
function Get-ScriptFunctionText {
    param(
        [Parameter(Mandatory = $true)][string]$ScriptName,
        [Parameter(Mandatory = $true)][string]$FunctionName
    )
    $ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $script:RepoRoot $ScriptName), [ref]$null, [ref]$null)
    $found = $ast.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $FunctionName }, $true)
    if (-not $found) {
        throw "No function $FunctionName in $ScriptName."
    }
    return $found.Extent.Text
}

# The text of an A1 exceptions file with one entry.
function New-A1ExceptionText {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
    param(
        [Parameter(Mandatory = $true)][string]$Sha256,
        [string]$Rule = 'Downloaded code run',
        [string]$File = 'Attack.ps1',
        [string]$Reason = 'known false positive in the test fixture',
        [string]$Expires = (Get-Date).AddMonths(6).ToString('yyyy-MM-dd')
    )
    return (@{ exceptions = @(@{ rule = $Rule; file = $File; sha256 = $Sha256; reason = $Reason; expires = $Expires }) } | ConvertTo-Json -Depth 3)
}

# The SHA-256 Attack.ps1 has once a fixture wrote the given text (UTF-8, no BOM, no newline added).
function Get-TextSha256 {
    param([Parameter(Mandatory = $true)][string]$Text)
    return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($Text)))
}

# A repository for A1's exceptions: main holds BaseExceptions (when given) at the default path, a
# 'work' branch adds Attack.ps1 and BranchExceptions (when given), and origin/main is the base
# commit. With -PullRequestMerge, the tested commit is a merge of 'work' into the base commit.
function New-ExceptionRepository {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Content,
        [string]$BaseExceptions = '',
        [string]$BranchExceptions = '',
        [switch]$PullRequestMerge
    )
    $repo = New-GitRepository -Name $Name
    $exceptionPath = Join-Path (Join-Path $repo '.security') 'a1-exceptions.json'
    New-Item -ItemType Directory -Path (Split-Path -Parent $exceptionPath) | Out-Null
    Set-Content -LiteralPath (Join-Path $repo 'README.md') -Value '# base' -NoNewline
    if ($BaseExceptions) {
        Set-Content -LiteralPath $exceptionPath -Value $BaseExceptions -NoNewline
    }
    Add-GitCommit -Repository $repo -Message 'base'
    $baseCommit = @(Invoke-Git -Repository $repo -Arguments @('rev-parse', 'HEAD'))[0]
    Invoke-Git -Repository $repo -Arguments @('checkout', '-b', 'work') | Out-Null
    Set-Content -LiteralPath (Join-Path $repo 'Attack.ps1') -Value $Content -NoNewline
    if ($BranchExceptions) {
        Set-Content -LiteralPath $exceptionPath -Value $BranchExceptions -NoNewline
    }
    Add-GitCommit -Repository $repo -Message 'attack'
    Invoke-Git -Repository $repo -Arguments @('update-ref', 'refs/remotes/origin/main', $baseCommit) | Out-Null
    if ($PullRequestMerge) {
        Invoke-Git -Repository $repo -Arguments @('checkout', '-b', 'merge', $baseCommit) | Out-Null
        Invoke-Git -Repository $repo -Arguments @('merge', '--no-ff', '-m', 'merge', 'work') | Out-Null
    }
    return $repo
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

# True when both hosts Grype needs answer: its GitHub release (the binary) and the
# Anchore database host (the listing). Otherwise the Network-tagged tests skip.
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
        [hashtable]$Environment = @{},
        [switch]$UseWindowsPowerShell
    )

    # A previous run of this ci-tools copy may have left a package next to its log: only
    # the package this run produces may be collected.
    $logDir = Join-Path $CiTools 'Logs'
    if (Test-Path -LiteralPath $logDir) {
        Get-ChildItem -LiteralPath $logDir -Filter '*.nupkg' | Remove-Item -Force
    }

    $result = Invoke-JobScript -CiTools $CiTools -ScriptName 'tec-pwsh-package-pack.ps1' `
        -RepositoryPath $RepositoryPath -Arguments (@{ PublishFeed = $PublishFeed } + $Arguments) -Environment $Environment -UseWindowsPowerShell:$UseWindowsPowerShell
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
