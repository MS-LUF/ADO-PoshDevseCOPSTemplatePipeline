<#
.SYNOPSIS
Tests for job A3, biz-pwsh-analysis-pester.ps1: the repository's Pester tests.
#>

BeforeAll {
    . (Join-Path $PSScriptRoot 'Helpers.ps1')
    $script:CiTools = New-CiToolsCopy -Name 'a3-tools' -Scripts @('biz-pwsh-analysis-pester.ps1') -WithTools
}

AfterAll {
    Remove-Scratch -Path $script:CiTools
}

Describe 'A3 Pester tests' {
    It 'runs no test when the change touches neither PowerShell code nor the test folder' {
        $repo = New-GitRepository -Name 'a3-json'
        try {
            New-Item -ItemType Directory -Path (Join-Path $repo 'Tests') -Force | Out-Null
            # A failing test: exit 0 then proves that the job did not run it.
            Set-Content -LiteralPath (Join-Path $repo 'Tests/Widget.Tests.ps1') -Value "Describe 'W' { It 'i' { 1 | Should -Be 2 } }" -NoNewline
            Add-GitCommit -Repository $repo -Message 'tests on main'
            $commit = @(Invoke-Git -Repository $repo -Arguments @('rev-parse', 'HEAD'))[0]
            Invoke-Git -Repository $repo -Arguments @('update-ref', 'refs/remotes/origin/main', $commit) | Out-Null
            Set-Content -LiteralPath (Join-Path $repo 'data.json') -Value '{}' -NoNewline
            Add-GitCommit -Repository $repo -Message 'json only'
            $r = Invoke-JobScript -CiTools $script:CiTools -ScriptName 'biz-pwsh-analysis-pester.ps1' -RepositoryPath $repo
            $r.ExitCode | Should -Be 0
        } finally { Remove-Scratch -Path $repo }
    }

    It 'passes when the changed tests pass' {
        $repo = New-AnalysisRepository -Name 'a3-pass' -ChangedFiles @{
            'Tests/Widget.Tests.ps1' = "Describe 'Widget' { It 'works' { 1 | Should -Be 1 } }"
        }
        try {
            $r = Invoke-JobScript -CiTools $script:CiTools -ScriptName 'biz-pwsh-analysis-pester.ps1' -RepositoryPath $repo -Environment @{ TF_BUILD = 'True' }
            $r.ExitCode | Should -Be 0
        } finally { Remove-Scratch -Path $repo }
    }

    It 'fails when a changed test fails, one annotation per failure' {
        $repo = New-AnalysisRepository -Name 'a3-fail' -ChangedFiles @{
            'Tests/Widget.Tests.ps1' = "Describe 'Widget' { It 'breaks' { 1 | Should -Be 2 }; It 'breaks too' { 1 | Should -Be 3 }; It 'works' { 1 | Should -Be 1 } }"
        }
        try {
            $r = Invoke-JobScript -CiTools $script:CiTools -ScriptName 'biz-pwsh-analysis-pester.ps1' -RepositoryPath $repo -Environment @{ TF_BUILD = 'True' }
            $r.ExitCode | Should -Be 1
            Get-AnnotationCount -Output $r.Output -Type error | Should -Be 2
        } finally { Remove-Scratch -Path $repo }
    }
}
