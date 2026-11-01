<#
.SYNOPSIS
Shared code of the CI scripts (A1, A2, A3, B1, B2), dot-sourced by each of them.
.DESCRIPTION
Defines the functions only; running it does nothing else. Each job script dot-sources it
from its own folder, so the functions run in the job script's scope: $script:fulllogpath,
$script:RepositoryRoot and $script:ScriptDirectory are the job script's variables.
Text that comes from the branch under test (file names, finding messages, git and error
output) is printed through Write-CILog and Show-CIIssue, which keep it from forming an
Azure Pipelines logging command: the agent runs any "##vso[" it finds in a line of stdout.
#>

#_____________________________________________________________________________________________________
# Define functions
Function Get-ScriptDirectory {
	[cmdletbinding()]
	Param ()
	if ($psISE) {
        $ScriptPath = Split-Path -Parent $psISE.CurrentFile.FullPath
    } elseif($PSVersionTable.PSVersion.Major -gt 3) {
        $ScriptPath = $PSScriptRoot
    } else {
        $ScriptPath = split-path -parent $MyInvocation.MyCommand.Path
    }
	$ScriptPath
}

# The agent runs "##vso[" wherever it appears in a line of stdout (case-sensitive): a space breaks
# the prefix. Only the console copy is changed; the log file keeps the original text.
function ConvertTo-CIConsoleText {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Text
    )

    $Text.Replace('##vso[', '##vso [')
}

# Creates the Logs folder next to the scripts and sets the job's log file ($script:fulllogpath).
function Initialize-CILog {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Prefix
    )

    $logpath = Join-Path $ScriptDirectory "Logs"
    if (!(test-path $logpath)) {
        New-Item -ItemType Directory -Path $logpath | out-null
    }
    $timefile = (get-date).ticks.tostring()
    $logfile = "$($Prefix)_$($env:BUILD_REPOSITORY_NAME)_$($env:BUILD_REQUESTEDFOR)_$($timefile).log"
    $script:fulllogpath = join-path $logpath $logfile
}

Function Write-CILog {
    [cmdletbinding()]
    param(
        [parameter(Mandatory=$true)]
        [ValidateSet("info", "warning", "error")]
            [string]$info,
        [parameter(Mandatory=$false)]
        [ValidateNotNullOrEmpty()]
            [string]$file = $script:fulllogpath,
        [parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
            [string]$message
    )
    if (!(test-path $file)) {
        New-Item -ItemType File -Path $file | out-null
        Add-Content -Path $file -value "INFO : File created on : $((get-date).ToString())"
    }
    Add-content -Path $file -value "$($info) : $($message)"
    $consoleMessage = ConvertTo-CIConsoleText -Text $message
    write-verbose "$($info) : $($consoleMessage)"
    if ($info -eq "warning") {
        write-warning -message $consoleMessage
    }
    if ($info -eq "error") {
        Write-Error -Message $consoleMessage -ErrorAction Continue
    }
}

# Shows a finding in the Azure DevOps build summary (task.logissue), pointing at its file and line.
# Outside Azure Pipelines (no TF_BUILD) it prints nothing: the log already holds the finding.
# The text is escaped as the agent documents, so it stays one command on one line. Write-Host:
# the agent reads logging commands from stdout, and the output stream is the function's return.
function Show-CIIssue {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('error', 'warning')]
        [string]$Type,
        [Parameter(Mandatory = $true)]
        [string]$Message,
        [string]$SourcePath,
        [int]$Line,
        [int]$Column,
        [string]$Code
    )

    if ($env:TF_BUILD -ne 'True') {
        return
    }
    $escapeProperty = {
        param([string]$Value)
        (ConvertTo-CIConsoleText -Text $Value).Replace(';', '%3B').Replace("`r", '%0D').Replace("`n", '%0A').Replace(']', '%5D')
    }
    $properties = @("type=$Type")
    if ($SourcePath) { $properties += "sourcepath=$(& $escapeProperty $SourcePath)" }
    if ($Line -gt 0) { $properties += "linenumber=$Line" }
    if ($Column -gt 0) { $properties += "columnnumber=$Column" }
    if ($Code) { $properties += "code=$(& $escapeProperty $Code)" }
    $text = $Message.Replace("`r", '%0D').Replace("`n", '%0A')
    Write-Host "##vso[task.logissue $($properties -join ';')]$(ConvertTo-CIConsoleText -Text $text)"
}

function Invoke-RepositoryGit {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments
    )

    $output = & git -C $script:RepositoryRoot @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "git $($Arguments -join ' ') failed (exit $LASTEXITCODE): $($output -join [Environment]::NewLine)"
    }
    $output | ForEach-Object { $_.ToString() }
}

# Sets $script:RepositoryRoot, checks that the tested commit is the checked-out one and returns it.
function Initialize-CIRepository {
    param(
        [string]$RepositoryPath
    )

    # The repository under test is never the one this script comes from when the pipeline checks
    # out a separate CI tooling repository, so the pipeline passes its folder.
    $script:RepositoryRoot = if ($RepositoryPath) {
        $RepositoryPath
    } elseif ($env:BUILD_SOURCESDIRECTORY) {
        $env:BUILD_SOURCESDIRECTORY
    } else {
        $ScriptDirectory
    }
    $script:RepositoryRoot = Invoke-RepositoryGit -Arguments @('rev-parse', '--show-toplevel')
    $commitReference = if ($env:BUILD_SOURCEVERSION) { $env:BUILD_SOURCEVERSION } else { 'HEAD' }
    $commit = Invoke-RepositoryGit -Arguments @('rev-parse', '--verify', "$commitReference^{commit}")
    $checkedOutCommit = Invoke-RepositoryGit -Arguments @('rev-parse', '--verify', 'HEAD')
    if ($commit -ne $checkedOutCommit) {
        throw "BUILD_SOURCEVERSION ($commit) does not match the checked-out commit ($checkedOutCommit)."
    }

    Write-CILog -info info -message "Commit user : $($env:BUILD_REQUESTEDFOR)" -Verbose
    Write-CILog -info info -message "Project : $($env:BUILD_REPOSITORY_NAME)" -Verbose
    Write-CILog -info info -message "Commit Branch : $($env:BUILD_SOURCEBRANCH)" -Verbose
    Write-CILog -info info -message "Commit SHA : $commit" -Verbose
    Write-CILog -info info -message "PowerShell : $($PSVersionTable.PSVersion) ($($PSVersionTable.PSEdition))" -Verbose
    $commit
}

# Returns the files added or changed by the tested range, relative to the repository root.
function Get-CIChangedFile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Commit,
        [Parameter(Mandatory = $true)]
        [string]$BaseBranch
    )

    # Every commit of the branch is compared, not only the last one of a push: a harmful commit
    # followed by a harmless one must not pass. This needs the full history (fetchDepth: 0).
    if ((Invoke-RepositoryGit -Arguments @('rev-parse', '--is-shallow-repository')) -eq 'true') {
        throw "Shallow checkout: the comparison needs the full history (checkout fetchDepth: 0)."
    }
    $parents = (Invoke-RepositoryGit -Arguments @('rev-list', '--parents', '-n', '1', $Commit)) -split ' '
    if ($env:BUILD_REASON -eq 'PullRequest') {
        # Azure DevOps PR builds test a merge commit; its first parent is the target.
        if ($parents.Count -lt 3) {
            throw "Expected an Azure DevOps pull request merge commit with two parents."
        }
        $baseCommit = $parents[1]
    } else {
        $baseReference = "refs/remotes/origin/$BaseBranch"
        if (-not (Invoke-RepositoryGit -Arguments @('for-each-ref', '--format=%(objectname)', $baseReference))) {
            throw "origin/$BaseBranch is not in the checkout: the comparison needs it (checkout fetchDepth: 0)."
        }
        $baseCommit = Invoke-RepositoryGit -Arguments @('merge-base', $baseReference, $Commit)
        if ($baseCommit -eq $Commit) {
            # The tested commit is already on the base branch: compare it to its parent.
            $baseCommit = if ($parents.Count -gt 1) { $parents[1] } else { $null }
        }
    }
    if ($baseCommit) {
        Write-CILog -info info -message "Comparison: $baseCommit -> $Commit" -Verbose
        $diffArguments = @('diff', '--name-only', '-z', '--diff-filter=ACMRT', $baseCommit, $Commit, '--')
    } else {
        Write-CILog -info info -message "Initial commit: looking at all added files." -Verbose
        $diffArguments = @('diff-tree', '--root', '--no-commit-id', '-r', '--name-only', '-z', '--diff-filter=ACMRT', $Commit, '--')
    }
    ((Invoke-RepositoryGit -Arguments $diffArguments) -join "`n") -split "`0" | Where-Object { $_ }
}

# Imports the exact version of a module: the bundled copy under internal-ci when present,
# otherwise an installed copy, installed from PSGallery when missing.
# A bundled module's parent folder is put first on PSModulePath, so that the test files and the
# child processes they start find the same version by name.
function Import-CIModule {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,
        [Parameter(Mandatory = $true)]
        [version]$Version
    )

    $bundledRoot = Join-Path (Join-Path $ScriptDirectory 'internal-ci') 'Security-PWSH-ADO-ci'
    $bundledModule = Join-Path (Join-Path $bundledRoot $Name) "$Name.psd1"
    if (Test-Path -LiteralPath $bundledModule -PathType Leaf) {
        $manifest = Test-ModuleManifest -Path $bundledModule
        if ($manifest.Version -ne $Version) {
            throw "Bundled $Name version $($manifest.Version) differs from required version $Version."
        }
        $env:PSModulePath = $bundledRoot + [System.IO.Path]::PathSeparator + $env:PSModulePath
        Write-CILog -info info -message "Using bundled $Name $Version." -Verbose
        Import-Module -Name $bundledModule -RequiredVersion $Version -Force
    } else {
        $installedModule = Get-Module -ListAvailable -Name $Name |
            Where-Object { $_.Version -eq $Version } |
            Select-Object -First 1
        if (-not $installedModule) {
            Write-CILog -info info -message "Installing $Name $Version." -Verbose
            Install-Module -Name $Name -RequiredVersion $Version -Force -AcceptLicense -AllowClobber -Scope CurrentUser -Repository PSGallery
        }
        Import-Module -Name $Name -RequiredVersion $Version -Force
    }
}

# Returns the changed scripts as paths for Invoke-ScriptAnalyzer, which reads -Path as a wildcard:
# a file named "a[1].ps1" would match nothing and pass with no finding, so each path is escaped,
# and must resolve to exactly the changed file.
function Get-CIAnalysisPath {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Files
    )

    foreach ($entry in $Files) {
        $changedFilePath = Join-Path $script:RepositoryRoot $entry
        if (-not (Test-Path -LiteralPath $changedFilePath -PathType Leaf)) {
            throw "Changed script not found in the checkout: $changedFilePath"
        }
        $analysisPath = [System.Management.Automation.WildcardPattern]::Escape($changedFilePath)
        $resolvedPaths = @(Resolve-Path -Path $analysisPath | ForEach-Object { $_.ProviderPath })
        if (($resolvedPaths.Count -ne 1) -or ($resolvedPaths[0] -ne (Resolve-Path -LiteralPath $changedFilePath).ProviderPath)) {
            throw "Changed script cannot be passed to the analyzer as one file: $changedFilePath"
        }
        Write-CILog -info info -message "Analyzing $changedFilePath" -Verbose
        $analysisPath
    }
}

# Logs PSScriptAnalyzer findings, shows each one in the build summary, and returns 1 when one of
# them fails the job (an Error, or a file that does not parse), 0 otherwise.
function Write-CIAnalysisResult {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [object[]]$Results,
        [Parameter(Mandatory = $true)]
        [string]$FailureMessage
    )

    if ($Results.Count -eq 0) {
        Write-CILog -info info -message "Analysis completed with no findings." -Verbose
        return 0
    }
    foreach ($result in $Results) {
        Write-CILog -info warning -message "$($result.ScriptName) - $($result.Severity) : $($result.RuleName) - $($result.Message) - $($result.Line)"
        $issueType = if (@('Error', 'ParseError') -contains "$($result.Severity)") { 'error' } else { 'warning' }
        Show-CIIssue -Type $issueType -Message "$($result.RuleName): $($result.Message)" -SourcePath $result.ScriptPath -Line $result.Line -Column $result.Column -Code $result.RuleName
    }
    # A file that does not parse is reported as ParseError, not Error: it fails the job too.
    if (($Results.Severity -contains 'Error') -or ($Results.Severity -contains 'ParseError')) {
        Write-CILog -info error -message $FailureMessage -Verbose
        return 1
    }
    0
}

# Logs an error caught by a job script's main block.
function Write-CIFailure {
    param(
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.ErrorRecord]$Failure
    )

    $errorDetails = @(
        $Failure.Exception.ToString()
        "Error ID: $($Failure.FullyQualifiedErrorId)"
        $Failure.InvocationInfo.PositionMessage
        $Failure.ScriptStackTrace
    ) -join [Environment]::NewLine
    Write-CILog -info error -message $errorDetails -Verbose
}

# Stops when the publishFeed parameter is not an https URL: empty (the parameter left out),
# relative, or another scheme. C1 calls it so that a pipeline without a usable feed fails
# on its first build, a PR included, and not only on the release tag's push; C2 calls it
# before pushing. Only https is accepted: the feed credentials travel with the push.
function Assert-CIPublishFeed {
    param(
        [AllowEmptyString()]
        [string]$Value
    )

    if (-not $Value) {
        throw "publishFeed is empty: set it to the feed's v3 URL (the feed's ""Connect to feed"" pane)."
    }
    $uri = $null
    if (-not [uri]::TryCreate($Value, [UriKind]::Absolute, [ref]$uri)) {
        throw "publishFeed is not an absolute URL: $Value."
    }
    if ($uri.Scheme -ne 'https') {
        throw "publishFeed must use https, not $($uri.Scheme): the feed credentials are sent with the push."
    }
}

# Reads the .nuspec at the root of a .nupkg (a zip) and returns the package id and version.
# Only a root entry counts: a .nuspec deeper in the module's own files is content, not the
# package's manifest. The archive is opened for reading only; nothing from it is run.
# GetElementsByTagName is used because the nuspec carries a default XML namespace.
function Get-CINupkgInfo {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = $null
    try {
        $zip = [System.IO.Compression.ZipFile]::OpenRead($Path)
        $entries = @($zip.Entries | Where-Object { $_.FullName -match '^[^/\\]+\.nuspec$' })
        if ($entries.Count -ne 1) {
            throw "$Path holds $($entries.Count) .nuspec files at its root, not exactly one."
        }
        $entry = $entries[0]
        $reader = New-Object System.IO.StreamReader($entry.Open())
        try {
            [xml]$nuspec = $reader.ReadToEnd()
        } finally {
            $reader.Dispose()
        }
        $id = $nuspec.GetElementsByTagName('id')[0].InnerText
        $version = $nuspec.GetElementsByTagName('version')[0].InnerText
        if (-not $id -or -not $version) {
            throw "The .nuspec inside $Path has no id or version."
        }
        [ordered]@{ Id = $id; Version = $version }
    } finally {
        if ($zip) {
            $zip.Dispose()
        }
    }
}
