<#
.SYNOPSIS
Tests for the comparison range every stage A job builds first: a checkout that cannot give it
stops the job, before any tool loads.
#>

BeforeAll {
    . (Join-Path $PSScriptRoot 'Helpers.ps1')
    $script:Scripts = @('sec-pwsh-analysis-malicious.ps1', 'tec-pwsh-analysis-practice.ps1', 'biz-pwsh-analysis-pester.ps1')
    $script:CiTools = New-CiToolsCopy -Name 'range-tools' -Scripts $script:Scripts
    $script:Source = New-AnalysisRepository -Name 'range-source' -ChangedFiles @{ 'Widget.ps1' = "function Get-Widget { 'widget' }" }
}

AfterAll {
    Remove-Scratch -Path $script:CiTools
    Remove-Scratch -Path $script:Source
}

Describe 'Stage A range' -ForEach @(
    @{ Job = 'A1'; ScriptName = 'sec-pwsh-analysis-malicious.ps1' }
    @{ Job = 'A2'; ScriptName = 'tec-pwsh-analysis-practice.ps1' }
    @{ Job = 'A3'; ScriptName = 'biz-pwsh-analysis-pester.ps1' }
) {
    It '<Job> stops when origin/main is missing' {
        $repo = New-AnalysisRepository -Name 'range-noorigin' -ChangedFiles @{ 'Widget.ps1' = "function Get-Widget { 'widget' }" }
        try {
            Invoke-Git -Repository $repo -Arguments @('update-ref', '-d', 'refs/remotes/origin/main') | Out-Null
            $r = Invoke-JobScript -CiTools $script:CiTools -ScriptName $ScriptName -RepositoryPath $repo
            $r.ExitCode | Should -Be 1
            $r.Output | Should -Match 'origin/main is not in the checkout'
        } finally { Remove-Scratch -Path $repo }
    }

    It '<Job> stops on a shallow clone' {
        $clone = New-ScratchDirectory -Name 'range-shallow'
        try {
            $sourceUri = 'file:///' + $script:Source.Replace('\', '/').TrimStart('/')
            & git clone -q --depth 1 --no-single-branch --branch work $sourceUri $clone 2>&1 | Out-Null
            $LASTEXITCODE | Should -Be 0
            Invoke-Git -Repository $clone -Arguments @('rev-parse', '--verify', 'refs/remotes/origin/main') | Out-Null
            $r = Invoke-JobScript -CiTools $script:CiTools -ScriptName $ScriptName -RepositoryPath $clone
            $r.ExitCode | Should -Be 1
            $r.Output | Should -Match 'Shallow checkout'
        } finally { Remove-Scratch -Path $clone }
    }
}
