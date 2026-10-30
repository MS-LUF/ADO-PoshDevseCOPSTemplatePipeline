<#
.SYNOPSIS
Analyzes the PowerShell files changed in the Azure DevOps tested commit with the default
PSScriptAnalyzer rules (coding practice).
.DESCRIPTION
Uses BUILD_SOURCESDIRECTORY and BUILD_SOURCEVERSION when available.
PR builds compare the tested merge commit to its first (target) parent.
Other builds compare the tested commit to its merge-base with the base branch,
so every commit of the branch is analyzed, not only the last one of a push.
The checkout must hold the full history and origin/BaseBranch (fetchDepth: 0);
no Git credentials are needed. The CI tooling folder is never analyzed.
On Azure Pipelines, each finding also shows in the build summary, at its file and line.
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
    [string]$RepositoryPath = ''
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
# Define log
$script:ScriptDirectory = Get-ScriptDirectory
Initialize-CILog -Prefix 'tec_pwsh_practice'

#_____________________________________________________________________________________________________
$customexitcode = 0
try {
    $ErrorActionPreference = 'Stop'
    $commit = Initialize-CIRepository -RepositoryPath $RepositoryPath
    $outputgitdiff = Get-CIChangedFile -Commit $commit -BaseBranch $BaseBranch
    # The CI tooling folder is never analyzed.
    $scriptFiles = @($outputgitdiff | Where-Object { $_ -match '\.(ps1|psm1|psd1)$' -and -not $_.StartsWith('internal-ci/') })
    $results = New-Object 'System.Collections.Generic.List[object]'

    if ($scriptFiles.Count -gt 0) {
        Import-CIModule -Name PSScriptAnalyzer -Version $PSScriptAnalyzerVersion

        $changedFilePaths = Get-CIAnalysisPath -Files $scriptFiles
        # One call for all the files: the rules load once, not once per file.
        # ParseError is listed, or a file that does not parse would pass with no finding.
        foreach ($result in @($changedFilePaths | Invoke-ScriptAnalyzer -Severity @('Error', 'Warning', 'Information', 'ParseError') -ErrorAction Stop)) {
            $results.Add($result)
        }
    } else {
        Write-CILog -info info -message "No changed PowerShell scripts to analyze." -Verbose
    }

    $customexitcode = Write-CIAnalysisResult -Results $results.ToArray() -FailureMessage "Potential unwanted pwsh coding practice found in commit files - exit job with error"
} catch {
    $customexitcode = 1
    Write-CIFailure -Failure $_
}
exit $customexitcode
