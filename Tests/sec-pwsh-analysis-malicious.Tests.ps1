<#
.SYNOPSIS
Tests for job A1, sec-pwsh-analysis-malicious.ps1: security analysis with the
Initialize-ASTRuleGenerator rules.
.DESCRIPTION
The attack sample is the module's own BaselineSample.txt, taken as data at run time and
written into the fixture repository (a .ps1 of this repository never holds it).
#>

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
            $r = Invoke-JobScript -CiTools $script:CiTools -ScriptName $script:ScriptName -RepositoryPath $repo -Environment @{ TF_BUILD = 'True' }
            $r.ExitCode | Should -Be 0
            $r.Output | Should -Not -Match 'task\.logissue'
        } finally { Remove-Scratch -Path $repo }
    }

    It 'fails the attack sample, with one error annotation per finding' {
        $repo = New-AnalysisRepository -Name 'a1-attack' -ChangedFiles @{ 'Attack.ps1' = (Get-AttackSample) }
        try {
            $r = Invoke-JobScript -CiTools $script:CiTools -ScriptName $script:ScriptName -RepositoryPath $repo -Environment @{ TF_BUILD = 'True' }
            $baseline = Get-BaselineFinding
            $r.ExitCode | Should -Be 1
            Get-AnnotationCount -Output $r.Output -Type error | Should -Be @($baseline | Where-Object Severity -eq 'Error').Count
            Get-AnnotationCount -Output $r.Output -Type warning | Should -Be @($baseline | Where-Object Severity -eq 'Warning').Count
        } finally { Remove-Scratch -Path $repo }
    }

    It 'fails a changed file that does not parse' {
        $repo = New-AnalysisRepository -Name 'a1-broken' -ChangedFiles @{ 'Broken.ps1' = 'function {' }
        try {
            $r = Invoke-JobScript -CiTools $script:CiTools -ScriptName $script:ScriptName -RepositoryPath $repo
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
            $r = Invoke-JobScript -CiTools $script:CiTools -ScriptName $script:ScriptName -RepositoryPath $repo
            $r.ExitCode | Should -Be 0
        } finally { Remove-Scratch -Path $repo }
    }

    It 'analyses a changed file whose name holds brackets (no silent skip)' {
        $repo = New-AnalysisRepository -Name 'a1-wildcard' -ChangedFiles @{ 'Evil[1].ps1' = (Get-AttackSample) }
        try {
            $r = Invoke-JobScript -CiTools $script:CiTools -ScriptName $script:ScriptName -RepositoryPath $repo -Environment @{ TF_BUILD = 'True' }
            $r.ExitCode | Should -Be 1
            Get-AnnotationCount -Output $r.Output -Type error -MessagePattern 'Evil\[1%5D\.ps1' | Should -Be @(Get-BaselineFinding | Where-Object Severity -eq 'Error').Count
        } finally { Remove-Scratch -Path $repo }
    }

    It 'neutralizes a logging-command in a file name of the branch' {
        $repo = New-AnalysisRepository -Name 'a1-logissue' -ChangedFiles @{
            '##vso[task.setvariable variable=PWNED]x.ps1' = $script:Harmless
        }
        try {
            $r = Invoke-JobScript -CiTools $script:CiTools -ScriptName $script:ScriptName -RepositoryPath $repo -Environment @{ TF_BUILD = 'True' }
            Get-ForeignLoggingCommand -Output $r.Output | Should -BeNullOrEmpty
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
                # The log, not the console: PowerShell wraps an error's long path there.
                (Get-CiLog -CiTools $bare -Raw) -join "`n" | Should -Match 'Initialize-ASTRuleGenerator\.json'
            } finally { Remove-Scratch -Path $repo }
        } finally { Remove-Scratch -Path $bare }
    }

    It 'runs the same cases under Windows PowerShell 5.1' -Tag 'WindowsPowerShell' -Skip:(-not (Get-Command powershell.exe -ErrorAction SilentlyContinue)) {
        $repo = New-AnalysisRepository -Name 'a1-w51' -ChangedFiles @{ 'Attack.ps1' = (Get-AttackSample) }
        try {
            $r = Invoke-JobScript -CiTools $script:CiTools -ScriptName $script:ScriptName -RepositoryPath $repo -UseWindowsPowerShell
            $r.ExitCode | Should -Be 1
        } finally { Remove-Scratch -Path $repo }
    }
}

Describe 'A1 range' {
    It 'fails an attack commit also when a harmless commit follows it' {
        $repo = New-AnalysisRepository -Name 'a1-followed' -ChangedFiles @{ 'Attack.ps1' = (Get-AttackSample) }
        try {
            Set-Content -LiteralPath (Join-Path $repo 'Widget.ps1') -Value $script:Harmless -NoNewline
            Add-GitCommit -Repository $repo -Message 'harmless'
            $r = Invoke-JobScript -CiTools $script:CiTools -ScriptName $script:ScriptName -RepositoryPath $repo -Environment @{ TF_BUILD = 'True' }
            $r.ExitCode | Should -Be 1
            Get-AnnotationCount -Output $r.Output -Type error | Should -Be @(Get-BaselineFinding | Where-Object Severity -eq 'Error').Count
        } finally { Remove-Scratch -Path $repo }
    }
}

Describe 'A1 parameter values (item 39)' {
    BeforeAll {
        $script:Marker = Join-Path (New-ScratchDirectory -Name 'a1-marker') 'ran.txt'
        $script:Injected = "main`$(Set-Content -LiteralPath '$($script:Marker)' -Value ran)"
    }

    AfterAll {
        Remove-Scratch -Path (Split-Path -Parent $script:Marker)
    }

    It 'keeps an injected value as text when it comes through env, as in the template' {
        $repo = New-AnalysisRepository -Name 'a1-inject' -ChangedFiles @{ 'Widget.ps1' = $script:Harmless }
        try {
            $wrapper = New-TaskWrapper -CiTools $script:CiTools -ScriptName $script:ScriptName -Arguments "-RepositoryPath '$repo' -BaseBranch `$env:CI_BASE_BRANCH"
            $r = Invoke-JobScript -CiTools $script:CiTools -ScriptName $wrapper -Environment @{ CI_BASE_BRANCH = $script:Injected }
            $r.ExitCode | Should -Be 1
            Test-Path -LiteralPath $script:Marker | Should -BeFalse
        } finally { Remove-Scratch -Path $repo }
    }

    It 'would run the same value written in the arguments: the check above can fail' {
        $repo = New-AnalysisRepository -Name 'a1-injectctl' -ChangedFiles @{ 'Widget.ps1' = $script:Harmless }
        try {
            $wrapper = New-TaskWrapper -CiTools $script:CiTools -ScriptName $script:ScriptName -Arguments "-RepositoryPath '$repo' -BaseBranch `"$($script:Injected)`""
            Invoke-JobScript -CiTools $script:CiTools -ScriptName $wrapper | Out-Null
            Test-Path -LiteralPath $script:Marker | Should -BeTrue
        } finally {
            Remove-Item -LiteralPath $script:Marker -ErrorAction SilentlyContinue
            Remove-Scratch -Path $repo
        }
    }
}

Describe 'A1 suppressed findings (item 40)' {
    BeforeAll {
        $line = Get-AttackSampleLine -RuleName 'Downloaded code run'
        $script:Suppressed = "function Get-Widget {`n    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('Downloaded code run', '')]`n    param()`n    $line`n}"
    }

    It 'still fails a file that suppresses its own Error finding' {
        $repo = New-ExceptionRepository -Name 'a1-suppressed' -Content $script:Suppressed
        try {
            $r = Invoke-JobScript -CiTools $script:CiTools -ScriptName $script:ScriptName -RepositoryPath $repo -Environment @{ TF_BUILD = 'True' }
            $r.ExitCode | Should -Be 1
            Get-AnnotationCount -Output $r.Output -Type error -MessagePattern 'Suppressed in the file, still counted' | Should -Be 1
        } finally { Remove-Scratch -Path $repo }
    }

    It 'passes it with an exception from the base branch' {
        $exceptions = New-A1ExceptionText -Sha256 (Get-TextSha256 -Text $script:Suppressed)
        $repo = New-ExceptionRepository -Name 'a1-suppressok' -Content $script:Suppressed -BaseExceptions $exceptions
        try {
            $r = Invoke-JobScript -CiTools $script:CiTools -ScriptName $script:ScriptName -RepositoryPath $repo -Environment @{ TF_BUILD = 'True' }
            $r.ExitCode | Should -Be 0
            Get-AnnotationCount -Output $r.Output -Type error | Should -Be 0
        } finally { Remove-Scratch -Path $repo }
    }
}

Describe 'A1 exceptions (base branch file, item 38)' {
    BeforeAll {
        # One line of the sample, one Error rule of the bundled set; no attack text in this file.
        $script:SingleAttack = Get-AttackSampleLine -RuleName 'Downloaded code run'
        $script:ValidExceptions = New-A1ExceptionText -Sha256 (Get-TextSha256 -Text $script:SingleAttack)
    }

    It 'downgrades an excepted Error finding to a warning and passes' {
        $repo = New-ExceptionRepository -Name 'a1-excepted' -Content $script:SingleAttack -BaseExceptions $script:ValidExceptions
        try {
            $r = Invoke-JobScript -CiTools $script:CiTools -ScriptName $script:ScriptName -RepositoryPath $repo -Environment @{ TF_BUILD = 'True' }
            $r.ExitCode | Should -Be 0
            Get-AnnotationCount -Output $r.Output -Type error | Should -Be 0
            Get-AnnotationCount -Output $r.Output -Type warning -MessagePattern 'known false positive in the test fixture' | Should -Be 1
        } finally { Remove-Scratch -Path $repo }
    }

    It 'keeps the Error when the exception is only on the branch' {
        $repo = New-ExceptionRepository -Name 'a1-branchonly' -Content $script:SingleAttack -BranchExceptions $script:ValidExceptions
        try {
            $r = Invoke-JobScript -CiTools $script:CiTools -ScriptName $script:ScriptName -RepositoryPath $repo -Environment @{ TF_BUILD = 'True' }
            $r.ExitCode | Should -Be 1
            Get-AnnotationCount -Output $r.Output -Type error -MessagePattern 'Downloaded content run as code' | Should -Be 1
        } finally { Remove-Scratch -Path $repo }
    }

    It 'keeps the Error when the file was edited after the exception' {
        $repo = New-ExceptionRepository -Name 'a1-edited' -Content ($script:SingleAttack + "`n# edited") -BaseExceptions $script:ValidExceptions
        try {
            $r = Invoke-JobScript -CiTools $script:CiTools -ScriptName $script:ScriptName -RepositoryPath $repo -Environment @{ TF_BUILD = 'True' }
            $r.ExitCode | Should -Be 1
            $r.Output | Should -Match 'the exception does not apply'
            Get-AnnotationCount -Output $r.Output -Type error -MessagePattern 'Downloaded content run as code' | Should -Be 1
        } finally { Remove-Scratch -Path $repo }
    }

    It 'fails on an entry with <Case>, even when nothing else fails' -ForEach @(
        @{ Case = 'an expiry in the past'; Field = 'Expires'; Value = '2020-01-01'; Problem = 'expired on' }
        @{ Case = 'an expiry over a year ahead'; Field = 'Expires'; Value = '2099-01-01'; Problem = 'at most one year' }
        @{ Case = 'an unknown rule'; Field = 'Rule'; Value = 'No such rule'; Problem = 'exact name of a bundled rule' }
        @{ Case = 'a wildcard file'; Field = 'File'; Value = '*.ps1'; Problem = 'one exact path' }
        @{ Case = 'a blank reason'; Field = 'Reason'; Value = ' '; Problem = 'a reason is required' }
        @{ Case = 'a malformed hash'; Field = 'Sha256'; Value = 'abc'; Problem = 'sha256 must be' }
    ) {
        $settings = @{ Sha256 = (Get-TextSha256 -Text $script:Harmless) }
        $settings[$Field] = $Value
        $repo = New-ExceptionRepository -Name 'a1-invalid' -Content $script:Harmless -BaseExceptions (New-A1ExceptionText @settings)
        try {
            $r = Invoke-JobScript -CiTools $script:CiTools -ScriptName $script:ScriptName -RepositoryPath $repo -Environment @{ TF_BUILD = 'True' }
            $r.ExitCode | Should -Be 1
            Get-AnnotationCount -Output $r.Output -Type error -MessagePattern $Problem | Should -Be 1
        } finally { Remove-Scratch -Path $repo }
    }

    It 'fails on an exceptions file that is not JSON' {
        $repo = New-ExceptionRepository -Name 'a1-notjson' -Content $script:Harmless -BaseExceptions 'not json'
        try {
            $r = Invoke-JobScript -CiTools $script:CiTools -ScriptName $script:ScriptName -RepositoryPath $repo -Environment @{ TF_BUILD = 'True' }
            $r.ExitCode | Should -Be 1
            Get-AnnotationCount -Output $r.Output -Type error -MessagePattern 'not valid JSON' | Should -Be 1
        } finally { Remove-Scratch -Path $repo }
    }

    It 'reads a pull request merge commit''s first parent: the base branch''s exception counts' {
        $repo = New-ExceptionRepository -Name 'a1-prbase' -Content $script:SingleAttack -BaseExceptions $script:ValidExceptions -PullRequestMerge
        try {
            $r = Invoke-JobScript -CiTools $script:CiTools -ScriptName $script:ScriptName -RepositoryPath $repo -Environment @{ BUILD_REASON = 'PullRequest' }
            $r.ExitCode | Should -Be 0
            $r.Output | Should -Match 'Accepted by exception'
        } finally { Remove-Scratch -Path $repo }
    }

    It 'reads a pull request merge commit''s first parent: the branch''s exception does not count' {
        $repo = New-ExceptionRepository -Name 'a1-prbranch' -Content $script:SingleAttack -BranchExceptions $script:ValidExceptions -PullRequestMerge
        try {
            $r = Invoke-JobScript -CiTools $script:CiTools -ScriptName $script:ScriptName -RepositoryPath $repo -Environment @{ BUILD_REASON = 'PullRequest' }
            $r.ExitCode | Should -Be 1
            $r.Output | Should -Not -Match 'Accepted by exception'
        } finally { Remove-Scratch -Path $repo }
    }
}
