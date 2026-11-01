<#
.SYNOPSIS
Tests for job C1, tec-pwsh-package-pack.ps1: packs the module into a .nupkg.
#>

. (Join-Path $PSScriptRoot 'Helpers.ps1')
BeforeAll {
    . (Join-Path $PSScriptRoot 'Helpers.ps1')
    . (Join-Path $script:RepoRoot 'pwsh-ci-common.ps1')
    $script:CiTools = New-CiToolsCopy -Name 'c1-tools' -Scripts @('tec-pwsh-package-pack.ps1') -WithTools
}

AfterAll {
    Remove-Scratch -Path $script:CiTools
}

Describe 'C1 pack, happy paths' {
    It 'packs the single root manifest into <Module>.<version>.nupkg' {
        $repo = New-ModuleRepository -Name 'c1-root' -Version '2.3.0'
        try {
            $r = Invoke-PackResult -CiTools $script:CiTools -RepositoryPath $repo
            $r.ExitCode | Should -Be 0
            $r.Nupkg | Should -Not -BeNullOrEmpty
            Split-Path -Leaf $r.Nupkg | Should -Be 'TestModule.2.3.0.nupkg'
            (Get-CINupkgInfo -Path $r.Nupkg).Id | Should -Be 'TestModule'
        } finally {
            Remove-Scratch -Path $repo
        }
    }

    It 'packs a manifest named by -PackageSpec in a subfolder' {
        $repo = New-ModuleRepository -Name 'c1-sub' -ManifestRelativePath 'src/MyModule/MyModule.psd1' -ModuleName 'MyModule' -Version '0.9.1'
        try {
            $r = Invoke-PackResult -CiTools $script:CiTools -RepositoryPath $repo -Arguments @{ PackageSpec = 'src/MyModule/MyModule.psd1' }
            $r.ExitCode | Should -Be 0
            Split-Path -Leaf $r.Nupkg | Should -Be 'MyModule.0.9.1.nupkg'
        } finally {
            Remove-Scratch -Path $repo
        }
    }

    It 'leaves the checkout .git out of the package and keeps the module files' {
        $repo = New-ModuleRepository -Name 'c1-gitfree' -ExtraFiles @{ 'Tests/inner.ps1' = '# kept' }
        try {
            $r = Invoke-PackResult -CiTools $script:CiTools -RepositoryPath $repo
            $r.ExitCode | Should -Be 0
            $entries = Get-NupkgEntry -Path $r.Nupkg
            ($entries | Where-Object { $_ -like '.git/*' -or $_ -eq '.git' }) | Should -BeNullOrEmpty
            ($entries | Where-Object { $_ -like 'TestModule.psd1' }) | Should -Not -BeNullOrEmpty
            ($entries | Where-Object { $_ -like 'Tests/inner.ps1' }) | Should -Not -BeNullOrEmpty
        } finally {
            Remove-Scratch -Path $repo
        }
    }

    It 'does not follow a symlink out of the module folder' -Skip:(-not (Test-SymlinkSupport)) {
        $repo = New-ModuleRepository -Name 'c1-symlink'
        $outsideFolder = New-ScratchDirectory -Name 'c1-symlink-outside'
        try {
            $outside = Join-Path $outsideFolder 'outside-secret.txt'
            Set-Content -Path $outside -Value 'top secret' -NoNewline
            New-Item -ItemType SymbolicLink -Path (Join-Path $repo 'linked.txt') -Target $outside | Out-Null
            Add-GitCommit -Repository $repo -Message 'link'
            $r = Invoke-PackResult -CiTools $script:CiTools -RepositoryPath $repo
            $r.ExitCode | Should -Be 0
            (Get-NupkgEntry -Path $r.Nupkg -Filter '*linked*') | Should -BeNullOrEmpty
        } finally {
            Remove-Scratch -Path $repo
            Remove-Scratch -Path $outsideFolder
        }
    }

    It 'packs under Windows PowerShell 5.1 too' -Tag 'WindowsPowerShell' -Skip:(-not (Get-Command powershell.exe -ErrorAction SilentlyContinue)) {
        $repo = New-ModuleRepository -Name 'c1-w51' -Version '1.6.0'
        try {
            $r = Invoke-PackResult -CiTools $script:CiTools -RepositoryPath $repo
            $r.ExitCode | Should -Be 0
            Split-Path -Leaf $r.Nupkg | Should -Be 'TestModule.1.6.0.nupkg'
        } finally {
            Remove-Scratch -Path $repo
        }
    }
}

Describe 'C1 pack, fail-closed cases' {
    It 'fails when the root holds two manifests and PackageSpec is empty' {
        $repo = New-ModuleRepository -Name 'c1-two'
        try {
            $other = "@{ RootModule = 'Other.psm1'; ModuleVersion = '1.0.0'; GUID = '$([guid]::NewGuid().ToString())'; Author = 't'; CompanyName = 't'; Description = 'd'; FunctionsToExport = '*' }"
            Set-Content -Path (Join-Path $repo 'Other.psd1') -Value $other -NoNewline
            Set-Content -Path (Join-Path $repo 'Other.psm1') -Value "function Get-Other { }" -NoNewline
            Add-GitCommit -Repository $repo -Message 'second manifest'
            $r = Invoke-PackResult -CiTools $script:CiTools -RepositoryPath $repo
            $r.ExitCode | Should -Be 1
            $r.Output | Should -Match 'not exactly one'
        } finally {
            Remove-Scratch -Path $repo
        }
    }

    It 'fails when PackageSpec escapes the repository' {
        $repo = New-ModuleRepository -Name 'c1-escape'
        try {
            $r = Invoke-PackResult -CiTools $script:CiTools -RepositoryPath $repo -Arguments @{ PackageSpec = '../outside.psd1' }
            $r.ExitCode | Should -Be 1
            $r.Output | Should -Match 'escapes the repository'
        } finally {
            Remove-Scratch -Path $repo
        }
    }

    It 'fails when PackageSpec is not a .psd1' {
        $repo = New-ModuleRepository -Name 'c1-ext'
        try {
            $r = Invoke-PackResult -CiTools $script:CiTools -RepositoryPath $repo -Arguments @{ PackageSpec = 'module.txt' }
            $r.ExitCode | Should -Be 1
            $r.Output | Should -Match 'not a \.psd1'
        } finally {
            Remove-Scratch -Path $repo
        }
    }

    It 'fails when PackageSpec does not exist in the checkout' {
        $repo = New-ModuleRepository -Name 'c1-missing'
        try {
            $r = Invoke-PackResult -CiTools $script:CiTools -RepositoryPath $repo -Arguments @{ PackageSpec = 'src/Gone.psd1' }
            $r.ExitCode | Should -Be 1
            $r.Output | Should -Match 'not found'
        } finally {
            Remove-Scratch -Path $repo
        }
    }

    It 'fails when the manifest has no ModuleVersion' {
        $repo = New-GitRepository -Name 'c1-nover'
        try {
            Set-Content -Path (Join-Path $repo 'Broken.psd1') -Value "@{ Author = 't' }" -NoNewline
            Set-Content -Path (Join-Path $repo 'Broken.psm1') -Value "function Get-Broken { }" -NoNewline
            Add-GitCommit -Repository $repo -Message 'no version'
            $r = Invoke-PackResult -CiTools $script:CiTools -RepositoryPath $repo
            $r.ExitCode | Should -Be 1
            $r.Output | Should -Match 'has no ModuleVersion'
        } finally {
            Remove-Scratch -Path $repo
        }
    }

    It 'fails when the manifest is not readable as data (never run)' {
        $repo = New-GitRepository -Name 'c1-notdata'
        try {
            Set-Content -Path (Join-Path $repo 'Sneaky.psd1') -Value "function Invoke-Sneaky { Get-Process }" -NoNewline
            Add-GitCommit -Repository $repo -Message 'not data'
            $r = Invoke-PackResult -CiTools $script:CiTools -RepositoryPath $repo
            $r.ExitCode | Should -Be 1
            $r.Output | Should -Match 'cannot be read as a data file'
        } finally {
            Remove-Scratch -Path $repo
        }
    }

    It 'fails when the shared pwsh-ci-common.ps1 is missing from the ci-tools copy' {
        $bare = New-ScratchDirectory -Name 'c1-bare-tools'
        try {
            Copy-Item -LiteralPath (Join-Path $script:RepoRoot 'tec-pwsh-package-pack.ps1') -Destination $bare
            $repo = New-ModuleRepository -Name 'c1-nocommon'
            try {
                $r = Invoke-JobScript -CiTools $bare -ScriptName 'tec-pwsh-package-pack.ps1' -RepositoryPath $repo
                $r.ExitCode | Should -Be 1
                $r.Output | Should -Match 'Shared CI code not found'
            } finally {
                Remove-Scratch -Path $repo
            }
        } finally {
            Remove-Scratch -Path $bare
        }
    }
}

Describe 'C1 tag version (item 36): a warning, never a failure' {
    BeforeAll {
        $script:TagRepo = New-ModuleRepository -Name 'c1-tag' -Version '2.3.0'
    }

    AfterAll {
        Remove-Scratch -Path $script:TagRepo
    }

    It 'gives <Warnings> warning(s) on <Ref>' -ForEach @(
        @{ Ref = 'refs/tags/v2.3.0'; Warnings = 0 }
        @{ Ref = 'refs/tags/2.3.0'; Warnings = 0 }
        @{ Ref = 'refs/tags/release/2.3.0'; Warnings = 0 }
        @{ Ref = 'refs/tags/V2.3.0.0'; Warnings = 0 }
        @{ Ref = 'refs/tags/v9.9.9'; Warnings = 1 }
        @{ Ref = 'refs/tags/latest'; Warnings = 1 }
        @{ Ref = 'refs/heads/v9.9.9'; Warnings = 0 }
    ) {
        $r = Invoke-PackResult -CiTools $script:CiTools -RepositoryPath $script:TagRepo -Environment @{ TF_BUILD = 'True'; BUILD_SOURCEBRANCH = $Ref }
        $r.ExitCode | Should -Be 0
        Split-Path -Leaf $r.Nupkg | Should -Be 'TestModule.2.3.0.nupkg'
        ([regex]::Matches($r.Output, '##vso\[task\.logissue type=warning[^\r\n]*code=TagVersion')).Count | Should -Be $Warnings
    }
}

Describe 'C1 file URI (item 35): a Linux path gives an absolute URI' {
    BeforeAll {
        . ([scriptblock]::Create((Get-ScriptFunctionText -ScriptName 'tec-pwsh-package-pack.ps1' -FunctionName 'ConvertTo-CIFileUri')))
    }

    It 'builds the URI of a Linux path, on any OS' {
        ConvertTo-CIFileUri -Path '/home/vsts/work/_temp/psresource-pack-1' | Should -Be 'file:///home/vsts/work/_temp/psresource-pack-1'
    }

    It 'builds the URI of a drive path' -Skip:(-not $IsWindows) {
        ConvertTo-CIFileUri -Path 'C:\agent\_temp\pack' | Should -Be 'file:///C:/agent/_temp/pack'
    }
}

Describe 'C1 publishFeed assertion' {
    It 'fails when PublishFeed is empty' {
        $repo = New-ModuleRepository -Name 'c1-feedempty'
        try {
            $r = Invoke-PackResult -CiTools $script:CiTools -RepositoryPath $repo -PublishFeed ''
            $r.ExitCode | Should -Be 1
            $r.Output | Should -Match 'publishFeed is empty'
        } finally {
            Remove-Scratch -Path $repo
        }
    }

    It 'fails when PublishFeed is not an absolute URL' {
        $repo = New-ModuleRepository -Name 'c1-feedrelative'
        try {
            $r = Invoke-PackResult -CiTools $script:CiTools -RepositoryPath $repo -PublishFeed 'feeds/tests/nuget/v3/index.json'
            $r.ExitCode | Should -Be 1
            $r.Output | Should -Match 'not an absolute URL'
        } finally {
            Remove-Scratch -Path $repo
        }
    }

    It 'fails when PublishFeed is not https' {
        $repo = New-ModuleRepository -Name 'c1-feedhttp'
        try {
            $r = Invoke-PackResult -CiTools $script:CiTools -RepositoryPath $repo -PublishFeed 'http://pkgs.example/tests/nuget/v3/index.json'
            $r.ExitCode | Should -Be 1
            $r.Output | Should -Match 'must use https'
        } finally {
            Remove-Scratch -Path $repo
        }
    }
}
