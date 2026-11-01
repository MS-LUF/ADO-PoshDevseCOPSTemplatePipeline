<#
.SYNOPSIS
Tests for job B1, tec-pwsh-sbom-inventory.ps1: the CycloneDX SBOM of the tested commit.
#>

BeforeAll {
    . (Join-Path $PSScriptRoot 'Helpers.ps1')
    $script:CiTools = New-CiToolsCopy -Name 'b1-tools' -Scripts @('tec-pwsh-sbom-inventory.ps1')
    $script:Repo = New-ModuleRepository -Name 'b1-fixture' -Version '1.2.3' `
        -ExtraContent "`n    RequiredModules = @('UnversionedModule')" `
        -ExtraFiles @{
            'src/Script.ps1'          = "#Requires -Modules RequiredMod`n`nWrite-Output 'x'"
            'lib/native.dll'          = 'MZ not a real binary'
            'app/packages.lock.json'  = '{"version":1,"dependencies":{"net8.0":{"Newtonsoft.Json":{"type":"Direct","requested":"[13.0.3, )","resolved":"13.0.3"}}}}'
        }
    $script:Result = Invoke-JobScript -CiTools $script:CiTools -ScriptName 'tec-pwsh-sbom-inventory.ps1' `
        -RepositoryPath $script:Repo -Arguments @{ TemplateRef = 'refs/tags/v0.0.0-tests' } `
        -Environment @{ BUILD_REPOSITORY_NAME = 'FixtureRepo' }
    $script:Sbom = $null
    $sbomPath = Join-Path $script:CiTools 'Logs/sbom.cdx.json'
    if (Test-Path -LiteralPath $sbomPath) {
        $script:Sbom = Get-Content -LiteralPath $sbomPath -Raw | ConvertFrom-Json
    }
}

AfterAll {
    Remove-Scratch -Path $script:CiTools
    Remove-Scratch -Path $script:Repo
}

Describe 'B1 SBOM inventory' {
    It 'passes and writes a CycloneDX 1.6 SBOM next to the log' {
        $script:Result.ExitCode | Should -Be 0
        $script:Sbom | Should -Not -BeNullOrEmpty
        $script:Sbom.bomFormat | Should -Be 'CycloneDX'
        $script:Sbom.specVersion | Should -Be '1.6'
    }

    It 'names the repository as the main component (BUILD_REPOSITORY_NAME)' {
        $script:Sbom.metadata.component.name | Should -Be 'FixtureRepo'
    }

    It 'lists the repository module as a component with its PSGallery purl' {
        $module = @($script:Sbom.components | Where-Object { $_.type -eq 'library' -and $_.name -eq 'TestModule' })
        $module.Count | Should -Be 1
        $module[0].version | Should -Be '1.2.3'
        $module[0].purl | Should -BeLike 'pkg:nuget/TestModule@1.2.3*'
    }

    It 'lists the lockfile package' {
        $pkg = @($script:Sbom.components | Where-Object { $_.name -eq 'Newtonsoft.Json' })
        $pkg.Count | Should -Be 1
        $pkg[0].version | Should -Be '13.0.3'
    }

    It 'lists a binary that is not a .NET assembly with its hash, as a warning' {
        $binary = @($script:Sbom.components | Where-Object { $_.name -eq 'native.dll' })
        $binary.Count | Should -Be 1
        $binary[0].hashes[0].alg | Should -Be 'SHA-256'
        $log = Get-CiLog -CiTools $script:CiTools -Raw
        ($log -join [Environment]::NewLine) | Should -Match 'not a \.NET assembly'
    }

    It 'warns about the RequiredModules entry without an exact version' {
        $log = Get-CiLog -CiTools $script:CiTools -Raw
        ($log -join [Environment]::NewLine) | Should -Match 'UnversionedModule'
    }
}
