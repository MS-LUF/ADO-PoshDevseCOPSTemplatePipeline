<#
.SYNOPSIS
Runs the repository Pester test suite when the Azure DevOps tested commit changes PowerShell code.
.DESCRIPTION
Uses BUILD_SOURCESDIRECTORY and BUILD_SOURCEVERSION when available.
PR builds compare the tested merge commit to its first (target) parent.
Other builds compare the tested commit to its merge-base with the base branch,
so every commit of the branch is covered, not only the last one of a push.
When that range adds or changes a ps1, psm1 or psd1 file, or a file of the test folder,
the whole test folder is run once; otherwise no test is run.
The CI tooling folder does not count.
The job fails when a test or a test container fails, or on any other error.
On Azure Pipelines, each failed test, block or container also shows in the build summary.
Test results are written as NUnit XML in the Logs folder, for PublishTestResults.
The checkout must hold the full history and origin/BaseBranch (fetchDepth: 0);
no Git credentials are needed.
The tests run the committed code: run this job only after the security analysis passed.
.PARAMETER PSPesterVersion
Exact Pester version, including for a bundled module. An installed version
is reused; PSGallery is contacted only when that version is missing.
.PARAMETER PSScriptAnalyzerVersion
Exact PSScriptAnalyzer version that the tests load. An installed version
is reused; PSGallery is contacted only when that version is missing.
.PARAMETER TestPath
Test folder, relative to the repository root.
.PARAMETER BaseBranch
Branch whose merge-base with the tested commit starts the compared range.
.PARAMETER RepositoryPath
Folder of the repository under test. A pipeline that checks out several repositories
passes it; otherwise BUILD_SOURCESDIRECTORY is used, then the folder of this script.
#>
[CmdletBinding()]
param(
    [version]$PSPesterVersion = '6.2.0',
    [version]$PSScriptAnalyzerVersion = '1.25.0',
    [string]$TestPath = 'Tests',
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
Initialize-CILog -Prefix 'biz_pwsh_pester'
$testResultPath = Join-Path (Join-Path $ScriptDirectory "Logs") "pester-testresults.xml"

#_____________________________________________________________________________________________________
$customexitcode = 0
try {
    $ErrorActionPreference = 'Stop'
    $commit = Initialize-CIRepository -RepositoryPath $RepositoryPath
    $outputgitdiff = Get-CIChangedFile -Commit $commit -BaseBranch $BaseBranch
    # The test data are code for the tests: a change alters what they expect.
    # The CI tooling folder is not the code under test.
    $testFolderPrefix = $TestPath.Replace('\', '/').TrimEnd('/') + '/'
    $codeFiles = @($outputgitdiff | Where-Object {
            -not $_.StartsWith('internal-ci/') -and
            ($_ -match '\.(ps1|psm1|psd1)$' -or $_.StartsWith($testFolderPrefix))
        })

    if ($codeFiles.Count -gt 0) {
        foreach ($entry in $codeFiles) {
            Write-CILog -info info -message "Changed PowerShell file: $entry" -Verbose
        }
        $testFolder = Join-Path $script:RepositoryRoot $TestPath
        if (-not (Test-Path -LiteralPath $testFolder -PathType Container)) {
            throw "Test folder not found in the checkout: $testFolder"
        }

        # Tests that import PSScriptAnalyzer by name get this version: loading it first pins it.
        Import-CIModule -Name PSScriptAnalyzer -Version $PSScriptAnalyzerVersion
        Import-CIModule -Name Pester -Version $PSPesterVersion

        $configuration = New-PesterConfiguration
        $configuration.Run.Path = $testFolder
        $configuration.Run.PassThru = $true
        $configuration.Output.Verbosity = 'Detailed'
        # Pester's own Azure DevOps annotations name no file: the failures are annotated below.
        $configuration.Output.CIFormat = 'None'
        $configuration.TestResult.Enabled = $true
        $configuration.TestResult.OutputFormat = 'NUnitXml'
        $configuration.TestResult.OutputPath = $testResultPath

        Write-CILog -info info -message "Running Pester $PSPesterVersion on $testFolder" -Verbose
        # Pester reports test failures in its result object; the preference stays at Continue so
        # that an error written by a test does not stop the run.
        $ErrorActionPreference = 'Continue'
        $testRun = Invoke-Pester -Configuration $configuration
        $ErrorActionPreference = 'Stop'

        if (-not $testRun) {
            throw "Pester returned no result."
        }
        Write-CILog -info info -message "Pester result : $($testRun.Result) - Total $($testRun.TotalCount), Passed $($testRun.PassedCount), Failed $($testRun.FailedCount), Skipped $($testRun.SkippedCount), NotRun $($testRun.NotRunCount), Failed blocks $($testRun.FailedBlocksCount), Failed containers $($testRun.FailedContainersCount)" -Verbose
        foreach ($test in $testRun.Failed) {
            $testError = ($test.ErrorRecord | ForEach-Object { $_.ToString() }) -join ' | '
            Write-CILog -info warning -message "Failed test : $($test.ExpandedPath) - $testError"
            Show-CIIssue -Type error -Message "Failed test $($test.ExpandedPath): $testError" -SourcePath $test.ScriptBlock.File -Line $test.StartLine
        }
        foreach ($block in $testRun.FailedBlocks) {
            $blockError = ($block.ErrorRecord | ForEach-Object { $_.ToString() }) -join ' | '
            Write-CILog -info warning -message "Failed block : $($block.Path -join '.') - $blockError"
            Show-CIIssue -Type error -Message "Failed block $($block.Path -join '.'): $blockError" -SourcePath $block.ScriptBlock.File -Line $block.StartLine
        }
        foreach ($container in $testRun.FailedContainers) {
            $containerError = ($container.ErrorRecord | ForEach-Object { $_.ToString() }) -join ' | '
            Write-CILog -info warning -message "Failed container : $($container.Item) - $containerError"
            $containerFile = if ($container.Type -eq 'File') { $container.Item.FullName } else { '' }
            Show-CIIssue -Type error -Message "Failed container $($container.Item): $containerError" -SourcePath $containerFile
        }
        if ($testRun.Result -ne 'Passed') {
            $customexitcode = 1
            Write-CILog -info error -message "Pester tests failed on the commit files - exit job with error" -Verbose
        } else {
            Write-CILog -info info -message "Pester tests passed." -Verbose
        }
    } else {
        Write-CILog -info info -message "No changed PowerShell files: no test to run." -Verbose
    }
} catch {
    $customexitcode = 1
    Write-CIFailure -Failure $_
}
exit $customexitcode
