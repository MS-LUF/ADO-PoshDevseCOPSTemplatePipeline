<#
.SYNOPSIS
Tests for job A2, tec-pwsh-analysis-practice.ps1: coding-practice analysis with the
default PSScriptAnalyzer rules.
#>

. (Join-Path $PSScriptRoot 'Helpers.ps1')

BeforeAll {
    . (Join-Path $PSScriptRoot 'Helpers.ps1')
    $script:CiTools = New-CiToolsCopy -Name 'a2-tools' -Scripts @('tec-pwsh-analysis-practice.ps1') -WithTools
    $script:ScriptName = 'tec-pwsh-analysis-practice.ps1'
}

AfterAll {
    Remove-Scratch -Path $script:CiTools
}

Describe 'A2 coding-practice analysis' {
    It 'passes a harmless file; a rule warning is an annotation, not a failure' {
        $repo = New-AnalysisRepository -Name 'a2-clean' -ChangedFiles @{ 'Widget.ps1' = "Write-Host 'hello'" }
        try {
            $r = Invoke-AnalysisResult -CiTools $script:CiTools -ScriptName $script:ScriptName -RepositoryPath $repo -Environment @{ TF_BUILD = 'True' }
            $r.ExitCode | Should -Be 0
            $r.Output | Should -Match 'task\.logissue type=warning'
        } finally { Remove-Scratch -Path $repo }
    }

    It 'fails a changed file that does not parse' {
        $repo = New-AnalysisRepository -Name 'a2-broken' -ChangedFiles @{ 'Broken.ps1' = 'function {' }
        try {
            $r = Invoke-AnalysisResult -CiTools $script:CiTools -ScriptName $script:ScriptName -RepositoryPath $repo
            $r.ExitCode | Should -Be 1
            $r.Output | Should -Match 'ParseError'
        } finally { Remove-Scratch -Path $repo }
    }

    It 'neutralizes a logging-command in a file name of the branch' {
        $repo = New-AnalysisRepository -Name 'a2-logissue' -ChangedFiles @{
            '##vso[task.setvariable variable=PWNED]x.ps1' = "Write-Host 'hello'"
        }
        try {
            $r = Invoke-AnalysisResult -CiTools $script:CiTools -ScriptName $script:ScriptName -RepositoryPath $repo -Environment @{ TF_BUILD = 'True' }
            $r.ExitCode | Should -Be 0
            $r.Output | Should -Not -Match '##vso[task.setvariable variable=PWNED]x'
            $r.Output | Should -Match '##vso \[task\.setvariable'
        } finally { Remove-Scratch -Path $repo }
    }

    It 'runs under Windows PowerShell 5.1 too' -Tag 'WindowsPowerShell' -Skip:(-not (Get-Command powershell.exe -ErrorAction SilentlyContinue)) {
        $repo = New-AnalysisRepository -Name 'a2-w51' -ChangedFiles @{ 'Widget.ps1' = "Write-Host 'hello'" }
        try {
            $r = Invoke-AnalysisResult -CiTools $script:CiTools -ScriptName $script:ScriptName -RepositoryPath $repo -UseWindowsPowerShell
            $r.ExitCode | Should -Be 0
        } finally { Remove-Scratch -Path $repo }
    }
}
