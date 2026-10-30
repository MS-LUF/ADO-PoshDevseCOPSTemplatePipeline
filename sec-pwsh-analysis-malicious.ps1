<#
.SYNOPSIS
Analyzes the PowerShell files changed in the Azure DevOps tested commit with the
Initialize-ASTRuleGenerator security rules.
.DESCRIPTION
Uses BUILD_SOURCESDIRECTORY and BUILD_SOURCEVERSION when available.
PR builds compare the tested merge commit to its first (target) parent.
Other builds compare the tested commit to its merge-base with the base branch,
so every commit of the branch is analyzed, not only the last one of a push.
The checkout must hold the full history and origin/BaseBranch (fetchDepth: 0);
no Git credentials are needed. The CI tooling folder is never analyzed.
On Azure Pipelines, each finding also shows in the build summary, at its file and line.
False positives are managed in an exceptions file read from the base branch, never from the
tested commit: an exception counts only once merged. Each entry names one rule of the bundled
rules, one file (relative path) and that file's SHA-256, with a reason and an expiry
(yyyy-MM-dd, at most one year ahead); the Error findings of that rule in that file, while the
file has that hash, become Warnings that show the reason. An invalid or expired entry fails
the job; ParseError findings and the encoding check are never excepted.
.PARAMETER ExceptionFile
The exceptions file, relative to the repository root, as it is on the base branch (a PR build:
its target). Empty: .security/a1-exceptions.json. A missing file means no exceptions.
.PARAMETER PSScriptAnalyzerVersion
Exact analyzer version, including for a bundled module. An installed version
is reused; PSGallery is contacted only when that version is missing.
.PARAMETER BaseBranch
Branch whose merge-base with the tested commit starts the compared range.
.PARAMETER RepositoryPath
Folder of the repository under test. A pipeline that checks out several repositories
passes it; otherwise BUILD_SOURCESDIRECTORY is used, then the folder of this script.
#>
[CmdletBinding()]
param(
    [version]$PSScriptAnalyzerVersion = '1.25.0',
    [string]$BaseBranch = 'main',
    [string]$RepositoryPath = '',
    [string]$ExceptionFile = ''
)

#_____________________________________________________________________________________________________
# Define functions: shared by the three CI scripts, in pwsh-ci-common.ps1 next to them
$commonScript = Join-Path $PSScriptRoot 'pwsh-ci-common.ps1'
if (-not (Test-Path -LiteralPath $commonScript -PathType Leaf)) {
    Write-Error -Message "Shared CI code not found: $commonScript" -ErrorAction Continue
    exit 1
}
. $commonScript

#_____________________________________________________________________________________________________
# Define functions: this job only

$script:DefaultExceptionFile = '.security/a1-exceptions.json'
$script:InvalidExceptionCount = 0

# Returns the commit whose exceptions file counts: the target of a PR build (the merge commit's
# first parent), else the tip of origin/BaseBranch. The tested commit's own file never counts,
# so a branch cannot excuse its own findings.
function Get-CIExceptionBaseCommit {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Commit,
        [Parameter(Mandatory = $true)]
        [string]$BaseBranch
    )

    if ($env:BUILD_REASON -eq 'PullRequest') {
        $parents = (Invoke-RepositoryGit -Arguments @('rev-list', '--parents', '-n', '1', $Commit)) -split ' '
        return $parents[1]
    }
    Invoke-RepositoryGit -Arguments @('rev-parse', '--verify', "refs/remotes/origin/$BaseBranch^{commit}")
}

# Reads and checks the exceptions file as it is in BaseCommit. Each entry needs a rule name of
# the bundled rules, an exact file path relative to the repository root, that file's SHA-256,
# a reason, and an expiry date (yyyy-MM-dd) from today to one year ahead. Returns the valid
# entries; each invalid one is logged and counted in $script:InvalidExceptionCount.
function Read-CIAnalysisException {
    param(
        [Parameter(Mandatory = $true)]
        [string]$BaseCommit,
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [Parameter(Mandatory = $true)]
        [string[]]$RuleNames
    )

    # A git path: relative, with forward slashes, no parent folder and no wildcard.
    if (($Path -notmatch '^[^/\\:*?\[\]]+(/[^/\\:*?\[\]]+)*$') -or ($Path.Split('/') -contains '..')) {
        throw "The exceptions file path must be relative to the repository root, with / separators and no '..': $Path"
    }
    $objectName = "$($BaseCommit):$Path"
    # A missing file is a normal case: git's stderr must not stop the job (Windows PowerShell
    # 5.1 turns it into an error under Stop), so only the exit code is read.
    $savedPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        & git -C $script:RepositoryRoot cat-file -e $objectName 2>&1 | Out-Null
        $fileExists = $LASTEXITCODE -eq 0
    } finally {
        $ErrorActionPreference = $savedPreference
    }
    if (-not $fileExists) {
        Write-CILog -info info -message "No exceptions file ($Path) on the base branch commit $BaseCommit." -Verbose
        return
    }
    $blob = Invoke-RepositoryGit -Arguments @('rev-parse', $objectName)
    Write-CILog -info info -message "Exceptions file: $Path as on the base branch commit $BaseCommit (blob $blob)." -Verbose
    $text = ((Invoke-RepositoryGit -Arguments @('show', $objectName)) -join "`n").TrimStart([char]0xFEFF)
    if ($text.StartsWith([string]::new([char[]](0xEF, 0xBB, 0xBF)))) {
        $text = $text.Substring(3)
    }
    try {
        $content = $text | ConvertFrom-Json
    } catch {
        $script:InvalidExceptionCount++
        Write-CILog -info error -message "The exceptions file is not valid JSON: $($_.Exception.Message)" -Verbose
        Show-CIIssue -Type error -Message "The exceptions file is not valid JSON." -SourcePath $Path -Code 'A1Exception'
        return
    }
    if ($null -eq $content.exceptions) {
        $script:InvalidExceptionCount++
        Write-CILog -info error -message "The exceptions file has no 'exceptions' list." -Verbose
        Show-CIIssue -Type error -Message "The exceptions file has no 'exceptions' list." -SourcePath $Path -Code 'A1Exception'
        return
    }
    $today = (Get-Date).ToUniversalTime().Date
    $index = 0
    foreach ($entry in @($content.exceptions)) {
        $index++
        $problems = @()
        $rule = "$($entry.rule)".Trim()
        $file = "$($entry.file)".Trim()
        $sha256 = "$($entry.sha256)".Trim().ToUpperInvariant()
        if ($RuleNames -cnotcontains $rule) {
            $problems += 'rule must be the exact name of a bundled rule'
        }
        if (($file -notmatch '^[^/\\:*?\[\]]+(/[^/\\:*?\[\]]+)*$') -or ($file.Split('/') -contains '..')) {
            $problems += "file must be one exact path relative to the repository root, with / separators"
        }
        if ($sha256 -notmatch '^[0-9A-F]{64}$') {
            $problems += 'sha256 must be the file''s SHA-256 (64 hexadecimal digits)'
        }
        if (-not "$($entry.reason)".Trim()) {
            $problems += 'a reason is required'
        }
        $expires = [datetime]::MinValue
        if (-not [datetime]::TryParseExact("$($entry.expires)", 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$expires)) {
            $problems += 'expires must be a date (yyyy-MM-dd)'
        } elseif ($expires -lt $today) {
            $problems += "expired on $($entry.expires)"
        } elseif ($expires -gt $today.AddYears(1)) {
            $problems += 'expires must be at most one year ahead'
        }
        if ($problems.Count -gt 0) {
            $script:InvalidExceptionCount++
            Write-CILog -info error -message "Exception $index ($rule, $file) is invalid: $($problems -join '; ')." -Verbose
            Show-CIIssue -Type error -Message "Exception $index ($rule, $file) is invalid: $($problems -join '; ')." -SourcePath $Path -Code 'A1Exception'
            continue
        }
        [pscustomobject]@{ Rule = $rule; File = $file; Sha256 = $sha256; Reason = "$($entry.reason)".Trim(); Expires = "$($entry.expires)"; Used = $false }
    }
}

# Turns each Error finding covered by an exception (same rule, same file, the file's SHA-256 at
# the tested commit equal to the entry's) into a Warning whose message gives the reason. Other
# findings, ParseError ones included, are returned unchanged. FilePaths maps the full path of
# each analysed file to its path relative to the repository root.
function Use-CIAnalysisException {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [object[]]$Results,
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [object[]]$Exceptions,
        [Parameter(Mandatory = $true)]
        [System.Collections.Generic.Dictionary[string, string]]$FilePaths
    )

    $hashes = @{}
    foreach ($result in $Results) {
        $relativePath = $null
        if ("$($result.Severity)" -eq 'Error' -and $result.ScriptPath) {
            $fullPath = [IO.Path]::GetFullPath($result.ScriptPath)
            if ($FilePaths.ContainsKey($fullPath)) {
                $relativePath = $FilePaths[$fullPath]
            }
        }
        $exception = $null
        if ($relativePath) {
            $candidates = @($Exceptions | Where-Object { $_.Rule -ceq "$($result.RuleName)" -and $_.File -ceq $relativePath })
            if ($candidates.Count -gt 0) {
                if (-not $hashes.ContainsKey($fullPath)) {
                    $hashes[$fullPath] = (Get-FileHash -LiteralPath $fullPath -Algorithm SHA256).Hash.ToUpperInvariant()
                }
                $exception = $candidates | Where-Object { $_.Sha256 -eq $hashes[$fullPath] } | Select-Object -First 1
                if (-not $exception) {
                    Write-CILog -info warning -message "An exception names $relativePath for rule $($result.RuleName), but the file's SHA-256 is now $($hashes[$fullPath]): the exception does not apply." -Verbose
                }
            }
        }
        if ($exception) {
            $exception.Used = $true
            [pscustomobject]@{
                ScriptName = $result.ScriptName
                ScriptPath = $result.ScriptPath
                Line       = $result.Line
                Column     = $result.Column
                RuleName   = $result.RuleName
                Severity   = 'Warning'
                Message    = "Accepted by exception (expires $($exception.Expires): $($exception.Reason)): $($result.Message)"
            }
        } else {
            $result
        }
    }
}

#_____________________________________________________________________________________________________
# Define log
$script:ScriptDirectory = Get-ScriptDirectory
Initialize-CILog -Prefix 'sec_pwsh_malicious'

#_____________________________________________________________________________________________________
$customexitcode = 0
try {
    $ErrorActionPreference = 'Stop'
    $commit = Initialize-CIRepository -RepositoryPath $RepositoryPath
    $outputgitdiff = Get-CIChangedFile -Commit $commit -BaseBranch $BaseBranch
    # The CI tooling folder is never analyzed.
    $scriptFiles = @($outputgitdiff | Where-Object { $_ -match '\.(ps1|psm1|psd1)$' -and -not $_.StartsWith('internal-ci/') })
    $results = New-Object 'System.Collections.Generic.List[object]'

    # The exceptions come from the base branch, read and checked on every run, so that an
    # invalid or expired entry fails even a build that changes no PowerShell file.
    $bundledRoot = Join-Path (Join-Path $ScriptDirectory 'internal-ci') 'Security-PWSH-ADO-ci'
    $bundledRules = Join-Path (Join-Path $bundledRoot 'Initialize-ASTRuleGenerator') 'Initialize-ASTRuleGenerator.json'
    $ruleNames = @((Get-Content -LiteralPath $bundledRules -Raw | ConvertFrom-Json).rules | ForEach-Object { "$($_.Name)" })
    $exceptionPath = if ($ExceptionFile) { $ExceptionFile } else { $script:DefaultExceptionFile }
    $baseCommit = Get-CIExceptionBaseCommit -Commit $commit -BaseBranch $BaseBranch
    $exceptions = @(Read-CIAnalysisException -BaseCommit $baseCommit -Path $exceptionPath -RuleNames $ruleNames)

    if ($scriptFiles.Count -gt 0) {
        Import-CIModule -Name PSScriptAnalyzer -Version $PSScriptAnalyzerVersion
        $custommodule = Join-Path (Join-Path $bundledRoot 'Initialize-ASTRuleGenerator') 'Initialize-ASTRuleGenerator.psd1'
        if (-not (Test-Path -LiteralPath $custommodule -PathType Leaf)) {
            throw "Custom analyzer module not found: $custommodule"
        }

        $changedFilePaths = Get-CIAnalysisPath -Files $scriptFiles
        # One call for all the files: the rules load once, not once per file.
        foreach ($result in @($changedFilePaths | Invoke-ScriptAnalyzer -CustomRulePath $custommodule -ErrorAction Stop)) {
            $results.Add($result)
        }
        # A file must not be able to hide its own findings with a suppression attribute. The way
        # to accept a false positive is the exceptions file, read from the base branch.
        foreach ($result in @($changedFilePaths | Invoke-ScriptAnalyzer -CustomRulePath $custommodule -SuppressedOnly -ErrorAction Stop)) {
            $results.Add([pscustomobject]@{
                    ScriptName = $result.ScriptName
                    ScriptPath = $result.ScriptPath
                    Line       = $result.Line
                    Column     = $result.Column
                    RuleName   = $result.RuleName
                    Severity   = "$($result.Severity)"
                    Message    = "Suppressed in the file, still counted: $($result.Message)"
                })
        }
    } else {
        Write-CILog -info info -message "No changed PowerShell scripts to analyze." -Verbose
    }

    $findings = $results.ToArray()
    if ($exceptions.Count -gt 0 -and $findings.Count -gt 0) {
        # Full path of each analysed file to its path relative to the repository root, compared
        # as the analyzer reports it (ordinal: a Linux file name keeps its case).
        $filePaths = New-Object 'System.Collections.Generic.Dictionary[string, string]' ([StringComparer]::Ordinal)
        foreach ($file in $scriptFiles) {
            $filePaths[[IO.Path]::GetFullPath((Join-Path $script:RepositoryRoot $file))] = $file
        }
        $findings = @(Use-CIAnalysisException -Results $findings -Exceptions $exceptions -FilePaths $filePaths)
    }
    foreach ($exception in @($exceptions | Where-Object { -not $_.Used })) {
        Write-CILog -info info -message "Exception for rule $($exception.Rule) in $($exception.File) matches no finding of this build." -Verbose
    }

    $customexitcode = Write-CIAnalysisResult -Results $findings -FailureMessage "Potential PWSH malicious code found in commit files - exit job with error"
    if ($script:InvalidExceptionCount -gt 0) {
        Write-CILog -info error -message "$($script:InvalidExceptionCount) invalid exception(s) in $exceptionPath on the base branch - exit job with error" -Verbose
        $customexitcode = 1
    }
} catch {
    $customexitcode = 1
    Write-CIFailure -Failure $_
}
exit $customexitcode
