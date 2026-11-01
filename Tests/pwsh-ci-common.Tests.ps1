<#
.SYNOPSIS
Tests for the shared functions of pwsh-ci-common.ps1, dot-sourced like a job script does.
#>

BeforeAll {
    . (Join-Path $PSScriptRoot 'Helpers.ps1')
    . (Join-Path $script:RepoRoot 'pwsh-ci-common.ps1')

    $script:LogTools = New-ScratchDirectory -Name 'common-log'
    $script:ScriptDirectory = $script:LogTools
    Initialize-CILog -Prefix 'test_common'
}

AfterAll {
    Remove-Scratch -Path $script:LogTools
}

Describe 'Get-ScriptDirectory' {
    It 'returns the folder of the dot-sourced shared file (the repository root here)' {
        Get-ScriptDirectory | Should -Be $script:RepoRoot
    }
}

Describe 'ConvertTo-CIConsoleText' {
    It 'breaks the ##vso[ logging-command prefix with a space' {
        ConvertTo-CIConsoleText -Text '##vso[task.setvariable variable=PWNED]x' | Should -Be '##vso [task.setvariable variable=PWNED]x'
    }

    It 'leaves text without the prefix unchanged' {
        ConvertTo-CIConsoleText -Text 'plain output' | Should -Be 'plain output'
    }
}

Describe 'Show-CIIssue' {
    BeforeAll {
        $script:SavedBuild = $env:TF_BUILD
        $env:TF_BUILD = 'True'
    }

    AfterAll {
        if ($null -eq $script:SavedBuild) { Remove-Item -LiteralPath 'Env:TF_BUILD' } else { $env:TF_BUILD = $script:SavedBuild }
    }

    It 'prints one command: no ##vso[ from <Field> stays live' -ForEach @(
        @{ Field = 'the source path'; Parameters = @{ Message = 'm'; SourcePath = 'src/##vso[task.setvariable variable=PWNED]x.ps1' } }
        @{ Field = 'the code'; Parameters = @{ Message = 'm'; Code = '##vso[task.complete]' } }
        @{ Field = 'the message'; Parameters = @{ Message = '##vso[task.complete]' } }
    ) {
        $line = (Show-CIIssue -Type error @Parameters 6>&1) | Out-String
        $line | Should -Match '^##vso\[task\.logissue type=error'
        Get-ForeignLoggingCommand -Output $line | Should -BeNullOrEmpty
        $line | Should -Match '##vso \['
    }

    It 'escapes a source path''s ] and ;' {
        $line = (Show-CIIssue -Type warning -Message 'm' -SourcePath 'a]b;c.ps1' 6>&1) | Out-String
        $line | Should -Match 'sourcepath=a%5Db%3Bc\.ps1'
    }
}

Describe 'Write-CILog' {
    It 'resolves the log path under <ScriptDirectory>\Logs and creates the folder' {
        $script:fulllogpath | Should -Not -BeNullOrEmpty
        Split-Path -Leaf $script:fulllogpath | Should -BeLike 'test_common_*.log'
        Test-Path -LiteralPath (Split-Path -Parent $script:fulllogpath) | Should -BeTrue
    }

    It 'writes the message to the file and a neutralized copy to the console' {
        $console = (Write-CILog -info info -message '##vso[task.setvariable variable=PWNED]x' -Verbose 4>&1) | Out-String
        (Get-Content -LiteralPath $script:fulllogpath -Raw) | Should -Match '##vso\[task\.setvariable'
        $console | Should -Not -Match '##vso\[task'
        $console | Should -Match '##vso \[task'
    }
}

Describe 'Get-CINupkgInfo' {
    BeforeAll {
        $script:NupkgDir = New-ScratchDirectory -Name 'common-nupkg'
        $nuspec = '<?xml version="1.0"?><package><metadata><id>Fancy.Tool</id><version>3.2.1</version></metadata></package>'
        Set-Content -Path (Join-Path $script:NupkgDir 'Fancy.Tool.nuspec') -Value $nuspec -NoNewline
        Compress-Archive -Path (Join-Path $script:NupkgDir 'Fancy.Tool.nuspec') -DestinationPath (Join-Path $script:NupkgDir 'Fancy.Tool.3.2.1.nupkg')
        $script:NupkgInfo = Get-CINupkgInfo -Path (Join-Path $script:NupkgDir 'Fancy.Tool.3.2.1.nupkg')
    }

    AfterAll {
        Remove-Scratch -Path $script:NupkgDir
    }

    It 'reads the id and version from the .nuspec at the root of the archive' {
        $script:NupkgInfo.Id | Should -Be 'Fancy.Tool'
        $script:NupkgInfo.Version | Should -Be '3.2.1'
    }

    It 'throws when the archive holds no root .nuspec' {
        $empty = New-ScratchDirectory -Name 'common-empty'
        try {
            Set-Content -Path (Join-Path $empty "readme.txt") -Value "no nuspec here" -NoNewline
            Compress-Archive -Path (Join-Path $empty "readme.txt") -DestinationPath (Join-Path $empty "x.zip")
            Rename-Item -Path (Join-Path $empty 'x.zip') -NewName 'x.nupkg'
            { Get-CINupkgInfo -Path (Join-Path $empty 'x.nupkg') } | Should -Throw
        } finally {
            Remove-Scratch -Path $empty
        }
    }
}
