<#
.SYNOPSIS
Tests for pwsh-ci.yml, read as text: a parameter's value must never run as code in a job.
.DESCRIPTION
The extending pipeline, which each branch edits, sets the parameters, and PowerShell@2 runs
"arguments" as PowerShell (backlog item 39). A value reaches a script through the step's env, with
every $ removed, and is compared at compile time.
#>

BeforeAll {
    . (Join-Path $PSScriptRoot 'Helpers.ps1')
    $script:Lines = @(Get-Content -LiteralPath (Join-Path $script:RepoRoot 'pwsh-ci.yml'))
}

Describe 'pwsh-ci.yml parameter values' {
    It 'names no parameter in a task''s arguments' {
        $arguments = @($script:Lines | Where-Object { $_ -match '^\s*arguments:' })
        $arguments.Count | Should -BeGreaterThan 0
        @($arguments | Where-Object { $_ -match 'parameters\.|\$\{\{' }) | Should -BeNullOrEmpty
    }

    It 'names no parameter in a runtime condition' {
        $conditions = @($script:Lines | Where-Object { $_ -match '^\s*condition:' })
        $conditions.Count | Should -BeGreaterThan 0
        @($conditions | Where-Object { $_ -match 'parameters\.' -and $_ -notmatch '^\s*condition:\s*\$\{\{' }) | Should -BeNullOrEmpty
    }

    It 'runs no inline script' {
        @($script:Lines | Where-Object { $_ -match '^\s*-?\s*(script|bash|pwsh|powershell):|targetType:\s*''?inline' }) | Should -BeNullOrEmpty
    }

    It 'removes every $ from each value it hands to a step''s env' {
        $values = @($script:Lines | Where-Object { $_ -match '^\s*CI_[A-Z0-9_]+:' })
        $values.Count | Should -BeGreaterThan 0
        @($values | Where-Object { $_ -notmatch '\$\{\{ replace\(parameters\.\w+, ''\$'', ''''\) \}\}\s*$' }) | Should -BeNullOrEmpty
    }
}
