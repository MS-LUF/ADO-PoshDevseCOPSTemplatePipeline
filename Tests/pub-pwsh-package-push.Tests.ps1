<#
.SYNOPSIS
Tests for job C2, pub-pwsh-package-push.ps1: pushes the packed .nupkg to the feed.
.DESCRIPTION
The happy path pushes to a real https feed (Azure Artifacts); it is verified by the
owner's runs (see Architecture.md, item 34). Everything up to the wire is covered here.
#>

. (Join-Path $PSScriptRoot 'Helpers.ps1')

BeforeAll {
    . (Join-Path $PSScriptRoot 'Helpers.ps1')
    . (Join-Path $script:RepoRoot 'pwsh-ci-common.ps1')
    $script:CiTools = New-CiToolsCopy -Name 'c2-tools' -Scripts @('pub-pwsh-package-push.ps1')
    $script:PackTools = New-CiToolsCopy -Name 'c2-pack-tools' -Scripts @('tec-pwsh-package-pack.ps1') -WithTools

    $moduleRepo = New-ModuleRepository -Name 'c2-module' -Version '4.5.6'
    $packed = Invoke-PackResult -CiTools $script:PackTools -RepositoryPath $moduleRepo
    Remove-Scratch -Path $moduleRepo
    if (-not $packed.Nupkg) {
        throw 'C2 fixture: C1 did not produce the .nupkg the push tests need.'
    }
    $script:NupkgSource = $packed.Nupkg
}

AfterAll {
    Remove-Scratch -Path $script:CiTools
    Remove-Scratch -Path $script:PackTools
}

Describe 'C2 push, fail-closed cases' {
    It 'fails when PublishFeed is empty' {
        $folder = New-NupkgFolder -SourceNupkg $script:NupkgSource -Name 'c2-feedempty'
        try {
            $r = Invoke-PushResult -CiTools $script:CiTools -PackageFolder $folder -PublishFeed ''
            $r.ExitCode | Should -Be 1
            $r.Output | Should -Match 'publishFeed is empty'
        } finally { Remove-Scratch -Path $folder }
    }

    It 'fails when PublishFeed is relative' {
        $folder = New-NupkgFolder -SourceNupkg $script:NupkgSource -Name 'c2-feedrelative'
        try {
            $r = Invoke-PushResult -CiTools $script:CiTools -PackageFolder $folder -PublishFeed 'feeds/tests/nuget/v3/index.json'
            $r.ExitCode | Should -Be 1
            $r.Output | Should -Match 'not an absolute URL'
        } finally { Remove-Scratch -Path $folder }
    }

    It 'fails when PublishFeed is not https' {
        $folder = New-NupkgFolder -SourceNupkg $script:NupkgSource -Name 'c2-feedhttp'
        try {
            $r = Invoke-PushResult -CiTools $script:CiTools -PackageFolder $folder -PublishFeed 'http://pkgs.example/tests/nuget/v3/index.json'
            $r.ExitCode | Should -Be 1
            $r.Output | Should -Match 'must use https'
        } finally { Remove-Scratch -Path $folder }
    }

    It 'fails when the package folder does not exist' {
        $r = Invoke-PushResult -CiTools $script:CiTools -PackageFolder (Join-Path $script:ScratchRoot 'no-such-folder-1')
        $r.ExitCode | Should -Be 1
        $r.Output | Should -Match 'Package folder not found'
    }

    It 'fails when the artifact holds two packages' {
        $folder = New-NupkgFolder -SourceNupkg $script:NupkgSource -Name 'c2-two' -Count 2
        try {
            $r = Invoke-PushResult -CiTools $script:CiTools -PackageFolder $folder
            $r.ExitCode | Should -Be 1
            $r.Output | Should -Match '2 \.nupkg files, not exactly one'
        } finally { Remove-Scratch -Path $folder }
    }

    It 'fails when dotnet is not on the PATH (agent without the .NET SDK)' {
        $folder = New-NupkgFolder -SourceNupkg $script:NupkgSource -Name 'c2-nodotnet'
        try {
            $r = Invoke-PushResult -CiTools $script:CiTools -PackageFolder $folder -WithoutDotnet
            $r.ExitCode | Should -Be 1
            $r.Output | Should -Match 'dotnet is not on the PATH'
        } finally { Remove-Scratch -Path $folder }
    }

    It 'fails when the feed is unreachable' {
        $folder = New-NupkgFolder -SourceNupkg $script:NupkgSource -Name 'c2-down'
        try {
            $r = Invoke-PushResult -CiTools $script:CiTools -PackageFolder $folder -PublishFeed 'https://127.0.0.1:1/nuget/v3/index.json'
            $r.ExitCode | Should -Be 1
        } finally { Remove-Scratch -Path $folder }
    }
}
