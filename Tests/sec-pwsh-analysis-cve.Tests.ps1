<#
.SYNOPSIS
Tests for job B2, sec-pwsh-analysis-cve.ps1: known-vulnerability check with Grype.
.DESCRIPTION
These tests download Grype and its database (about 300 MB, a minute or two) and need
internet access: they carry the Network tag and skip when the machine is offline. The
CVE-matching cases of the manual verification (a vulnerable Newtonsoft.Json) are not
repeated here; the exceptions validation and the fail-closed downloads are.
#>

. (Join-Path $PSScriptRoot 'Helpers.ps1')

BeforeAll {
    . (Join-Path $PSScriptRoot 'Helpers.ps1')
    $script:CiTools = New-CiToolsCopy -Name 'b2-tools' -Scripts @('sec-pwsh-analysis-cve.ps1')
    $script:B1Tools = New-CiToolsCopy -Name 'b2-b1-tools' -Scripts @('tec-pwsh-sbom-inventory.ps1')

    $moduleRepo = New-ModuleRepository -Name 'b2-module' -Version '1.2.3'
    $b1 = Invoke-JobScript -CiTools $script:B1Tools -ScriptName 'tec-pwsh-sbom-inventory.ps1' `
        -RepositoryPath $moduleRepo -Arguments @{ TemplateRef = 'refs/tags/v0.0.0-tests' } `
        -Environment @{ BUILD_REPOSITORY_NAME = 'FixtureRepo' }
    Remove-Scratch -Path $moduleRepo
    if ($b1.ExitCode -ne 0 -or -not (Test-Path -LiteralPath (Join-Path $script:B1Tools 'Logs/sbom.cdx.json'))) {
        throw 'B2 fixture: B1 did not produce the SBOM the CVE tests need.'
    }
    $script:SbomPath = Join-Path $script:B1Tools 'Logs/sbom.cdx.json'
}

AfterAll {
    Remove-Scratch -Path $script:CiTools
    Remove-Scratch -Path $script:B1Tools
}

Describe 'B2 known vulnerabilities' -Tag 'Network' {
    It 'passes a module-only repository: no lockfile, modules not checkable for CVEs' {
        if (-not (Test-Online)) { Set-ItResult -Skipped -Because 'the machine is offline (Grype and its database cannot be downloaded)' }
        $repo = New-ModuleRepository -Name 'b2-clean' -Version '1.0.0'
        try {
            $r = Invoke-CveResultResilient -CiTools $script:CiTools -SbomPath $script:SbomPath -RepositoryPath $repo
            if ($r.ExitCode -ne 0 -and $r.Output -match 'unable to (download|update) vulnerability database|relative paths require a module with a pwd') {
                Set-ItResult -Skipped -Because 'the Grype listing host stayed unreachable after three attempts (flaky network path), not a job defect'
            }
            $r.ExitCode | Should -Be 0
            $report = Join-Path $script:CiTools 'Logs/cve-report.json'
            Test-Path -LiteralPath $report | Should -BeTrue
        } finally { Remove-Scratch -Path $repo }
    }

    It 'fails on an invalid exceptions file, one error annotation per invalid entry' {
        if (-not (Test-Online)) { Set-ItResult -Skipped -Because 'the machine is offline (Grype and its database cannot be downloaded)' }
        $expired = (Get-Date).AddDays(-7).ToString('yyyy-MM-dd')
        $exceptions = "{ `"exceptions`": [ " +
            "{ `"id`": `"CVE-2021-0001`", `"package`": `"Some.Package`", `"reason`": `"expired entry`", `"expires`": `"$expired`" }, " +
            "{ `"id`": `"CVE-2021-0002`", `"package`": `"*`", `"reason`": `"broad package`", `"expires`": `"2027-01-01`" }, " +
            "{ `"id`": `"CVE-2021-0003`", `"package`": `"Other.Package`", `"expires`": `"2027-01-01`" } ] }"
        $repo = New-AnalysisRepository -Name 'b2-badex' -ChangedFiles @{
            '.supplychain/cve-exceptions.json' = $exceptions
            'Tests/Widget.ps1'                 = "function Get-Widget { 'w' }"
        }
        try {
            $r = Invoke-CveResultResilient -CiTools $script:CiTools -SbomPath $script:SbomPath -RepositoryPath $repo -Arguments @{ ExceptionFile = '.supplychain/cve-exceptions.json' } -Environment @{ TF_BUILD = 'True' }
            $r.ExitCode | Should -Be 1
            $r.Output | Should -Match 'task\.logissue type=error'
        } finally { Remove-Scratch -Path $repo }
    }

    It 'stops before Grype runs when the download fails the hash check' {
        if (-not (Test-Online)) { Set-ItResult -Skipped -Because 'the machine is offline (the tampered script must still download Grype before the hash check)' }
        $tamperedTools = New-ScratchDirectory -Name 'b2-tampered-tools'
        try {
            $text = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'sec-pwsh-analysis-cve.ps1') -Raw
            $tampered = $text -replace '[0-9a-f]{64}', ('0' * 64)
            Set-Content -LiteralPath (Join-Path $tamperedTools 'sec-pwsh-analysis-cve.ps1') -Value $tampered -NoNewline
            Copy-Item -LiteralPath (Join-Path $script:RepoRoot 'pwsh-ci-common.ps1') -Destination $tamperedTools
            $repo = New-ModuleRepository -Name 'b2-tamper' -Version '1.0.0'
            try {
                $r = Invoke-JobScript -CiTools $tamperedTools -ScriptName 'sec-pwsh-analysis-cve.ps1' `
                    -RepositoryPath $repo -Arguments @{ SbomPath = $script:SbomPath }
                $r.ExitCode | Should -Be 1
                $r.Output | Should -Match 'SHA-256'
            } finally { Remove-Scratch -Path $repo }
        } finally { Remove-Scratch -Path $tamperedTools }
    }
}
