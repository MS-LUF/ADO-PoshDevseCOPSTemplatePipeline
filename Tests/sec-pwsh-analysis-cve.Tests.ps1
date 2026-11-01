<#
.SYNOPSIS
Tests for job B2, sec-pwsh-analysis-cve.ps1: known-vulnerability check with Grype.
.DESCRIPTION
The exceptions file's validation runs offline, on the function taken from the script. The
Network tests download Grype and need internet access; they skip when the machine is offline.
They share one vulnerability database (about 85 s to prepare on Windows, 150 s on Linux): their
copy of the script differs from the real one only by the database's folder.
#>

BeforeAll {
    . (Join-Path $PSScriptRoot 'Helpers.ps1')
}

Describe 'B2 exceptions file, offline' {
    BeforeAll {
        . (Join-Path $script:RepoRoot 'pwsh-ci-common.ps1')
        . ([scriptblock]::Create((Get-ScriptFunctionText -ScriptName 'sec-pwsh-analysis-cve.ps1' -FunctionName 'Read-CICveException')))
        $script:LogTools = New-ScratchDirectory -Name 'b2-offline'
        $script:ScriptDirectory = $script:LogTools
        Initialize-CILog -Prefix 'test_b2'
        $script:ExceptionPath = Join-Path $script:LogTools 'cve-exceptions.json'
        # The function names the script's parameter in one message.
        $script:ExceptionFile = 'cve-exceptions.json'
        $script:Valid = (Get-Date).AddMonths(6).ToString('yyyy-MM-dd')

        function Read-Entry {
            param([hashtable]$Entry)
            $text = @{ exceptions = @($Entry) } | ConvertTo-Json -Depth 3
            Set-Content -LiteralPath $script:ExceptionPath -Value $text -NoNewline
            @(Read-CICveException -Path $script:ExceptionPath 2>$null 4>$null)
        }
    }

    AfterAll {
        Remove-Scratch -Path $script:LogTools
    }

    It 'returns a valid entry' {
        $entries = Read-Entry -Entry @{ id = 'GHSA-5crp-9r3c-p9vr'; package = 'Newtonsoft.Json'; reason = 'r'; expires = $script:Valid }
        $script:InvalidExceptionCount | Should -Be 0
        $entries.Count | Should -Be 1
        $entries[0].Id | Should -Be 'GHSA-5crp-9r3c-p9vr'
    }

    It 'refuses and counts <Case>' -ForEach @(
        @{ Case = 'a broad id'; Id = 'CVE-*'; Package = 'P'; Reason = 'r'; Expires = 'valid' }
        @{ Case = 'a broad package'; Id = 'CVE-2021-0001'; Package = '*'; Reason = 'r'; Expires = 'valid' }
        @{ Case = 'a blank reason'; Id = 'CVE-2021-0001'; Package = 'P'; Reason = ' '; Expires = 'valid' }
        @{ Case = 'an expiry in the past'; Id = 'CVE-2021-0001'; Package = 'P'; Reason = 'r'; Expires = '2020-01-01' }
        @{ Case = 'an expiry over a year ahead'; Id = 'CVE-2021-0001'; Package = 'P'; Reason = 'r'; Expires = '2099-01-01' }
        @{ Case = 'a malformed expiry'; Id = 'CVE-2021-0001'; Package = 'P'; Reason = 'r'; Expires = 'soon' }
    ) {
        $when = if ($Expires -eq 'valid') { $script:Valid } else { $Expires }
        $entries = Read-Entry -Entry @{ id = $Id; package = $Package; reason = $Reason; expires = $when }
        $script:InvalidExceptionCount | Should -Be 1
        $entries.Count | Should -Be 0
    }

    It 'counts each invalid entry and keeps the valid one' {
        $text = @{ exceptions = @(
                @{ id = 'CVE-2021-0001'; package = '*'; reason = 'r'; expires = $script:Valid }
                @{ id = 'CVE-2021-0002'; package = 'P'; reason = 'r'; expires = $script:Valid }
                @{ id = 'CVE-2021-0003'; package = 'P'; reason = ''; expires = $script:Valid }
            ) } | ConvertTo-Json -Depth 3
        Set-Content -LiteralPath $script:ExceptionPath -Value $text -NoNewline
        $entries = @(Read-CICveException -Path $script:ExceptionPath 2>$null 4>$null)
        $script:InvalidExceptionCount | Should -Be 2
        $entries.Count | Should -Be 1
    }

    It 'counts a file that is not JSON or has no list' -ForEach @(
        @{ Text = 'not json' }
        @{ Text = '{ "other": [] }' }
    ) {
        Set-Content -LiteralPath $script:ExceptionPath -Value $Text -NoNewline
        @(Read-CICveException -Path $script:ExceptionPath 2>$null 4>$null).Count | Should -Be 0
        $script:InvalidExceptionCount | Should -Be 1
    }

    It 'takes a missing file as no exception' {
        @(Read-CICveException -Path (Join-Path $script:LogTools 'missing.json') 2>$null 4>$null).Count | Should -Be 0
        $script:InvalidExceptionCount | Should -Be 0
    }
}

Describe 'B2 known vulnerabilities' -Tag 'Network' {
    BeforeAll {
        $script:CiTools = New-CiToolsCopy -Name 'b2-tools' -Scripts @('sec-pwsh-analysis-cve.ps1')
        $script:B1Tools = New-CiToolsCopy -Name 'b2-b1-tools' -Scripts @('tec-pwsh-sbom-inventory.ps1')

        # One database for every scan: the first run prepares it, the next find it up to date.
        $script:GrypeDb = New-ScratchDirectory -Name 'b2-db'
        $scriptCopy = Join-Path $script:CiTools 'sec-pwsh-analysis-cve.ps1'
        $text = Get-Content -LiteralPath $scriptCopy -Raw
        $cacheLine = '$env:GRYPE_DB_CACHE_DIR = Join-Path $workFolder ''db'''
        if (-not $text.Contains($cacheLine)) {
            throw 'B2 fixture: the database folder line of the script has changed.'
        }
        Set-Content -LiteralPath $scriptCopy -Value $text.Replace($cacheLine, "`$env:GRYPE_DB_CACHE_DIR = '$($script:GrypeDb)'") -NoNewline

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
        Remove-Scratch -Path $script:GrypeDb
    }

    It 'passes a module-only repository: no lockfile, modules not checkable for CVEs' {
        if (-not (Test-Online)) { Set-ItResult -Skipped -Because 'the machine is offline (Grype and its database cannot be downloaded)' }
        $repo = New-ModuleRepository -Name 'b2-clean' -Version '1.0.0'
        try {
            $r = Invoke-CveResult -CiTools $script:CiTools -SbomPath $script:SbomPath -RepositoryPath $repo
            $r.ExitCode | Should -Be 0
            $report = Join-Path $script:CiTools 'Logs/cve-report.json'
            Test-Path -LiteralPath $report | Should -BeTrue
        } finally { Remove-Scratch -Path $repo }
    }

    It 'fails on an invalid exceptions file, one error annotation per invalid entry' {
        if (-not (Test-Online)) { Set-ItResult -Skipped -Because 'the machine is offline (Grype and its database cannot be downloaded)' }
        $expired = (Get-Date).AddDays(-7).ToString('yyyy-MM-dd')
        $valid = (Get-Date).AddMonths(6).ToString('yyyy-MM-dd')
        $exceptions = "{ `"exceptions`": [ " +
            "{ `"id`": `"CVE-2021-0001`", `"package`": `"Some.Package`", `"reason`": `"expired entry`", `"expires`": `"$expired`" }, " +
            "{ `"id`": `"CVE-2021-0002`", `"package`": `"*`", `"reason`": `"broad package`", `"expires`": `"$valid`" }, " +
            "{ `"id`": `"CVE-2021-0003`", `"package`": `"Other.Package`", `"expires`": `"$valid`" } ] }"
        $repo = New-AnalysisRepository -Name 'b2-badex' -ChangedFiles @{
            '.supplychain/cve-exceptions.json' = $exceptions
            'Tests/Widget.ps1'                 = "function Get-Widget { 'w' }"
        }
        try {
            $r = Invoke-CveResult -CiTools $script:CiTools -SbomPath $script:SbomPath -RepositoryPath $repo -Arguments @{ ExceptionFile = '.supplychain/cve-exceptions.json' } -Environment @{ TF_BUILD = 'True' }
            $r.ExitCode | Should -Be 1
            Get-AnnotationCount -Output $r.Output -Type error -MessagePattern 'is invalid' | Should -Be 3
            # The summary comes after the scans: the exit 1 is the entries', not a failed download.
            $r.Output | Should -Match 'Findings: 0, failing: 0'
        } finally { Remove-Scratch -Path $repo }
    }

    Context 'a vulnerable package in a lockfile' {
        BeforeAll {
            $script:VulnerableLock = '{"version":1,"dependencies":{"net8.0":{"Newtonsoft.Json":{"type":"Direct","requested":"[12.0.3, )","resolved":"12.0.3"}}}}'
        }

        It 'fails on it' {
            if (-not (Test-Online)) { Set-ItResult -Skipped -Because 'the machine is offline (Grype and its database cannot be downloaded)' }
            $repo = New-AnalysisRepository -Name 'b2-vuln' -ChangedFiles @{ 'app/packages.lock.json' = $script:VulnerableLock }
            try {
                $r = Invoke-CveResult -CiTools $script:CiTools -SbomPath $script:SbomPath -RepositoryPath $repo -Environment @{ TF_BUILD = 'True' }
                $r.ExitCode | Should -Be 1
                $r.Output | Should -Match 'Findings: [1-9]\d*, failing: [1-9]'
                Get-AnnotationCount -Output $r.Output -Type error -MessagePattern 'Newtonsoft\.Json' | Should -BeGreaterThan 0
            } finally { Remove-Scratch -Path $repo }
        }

        It 'passes on it with a valid exception' {
            if (-not (Test-Online)) { Set-ItResult -Skipped -Because 'the machine is offline (Grype and its database cannot be downloaded)' }
            $expires = (Get-Date).AddMonths(6).ToString('yyyy-MM-dd')
            $repo = New-AnalysisRepository -Name 'b2-vulnok' -ChangedFiles @{
                'app/packages.lock.json'           = $script:VulnerableLock
                '.supplychain/cve-exceptions.json' = "{ `"exceptions`": [ { `"id`": `"GHSA-5crp-9r3c-p9vr`", `"package`": `"Newtonsoft.Json`", `"reason`": `"test fixture`", `"expires`": `"$expires`" } ] }"
            }
            try {
                $r = Invoke-CveResult -CiTools $script:CiTools -SbomPath $script:SbomPath -RepositoryPath $repo -Environment @{ TF_BUILD = 'True' }
                $r.ExitCode | Should -Be 0
                $r.Output | Should -Match 'Findings: [1-9]\d*, failing: 0'
            } finally { Remove-Scratch -Path $repo }
        }
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
