<#
.SYNOPSIS
Tests for job B3, tec-pwsh-sbom-publish.ps1: preflight checks that need no server.
.DESCRIPTION
The happy path (a real upload) needs an https Dependency-Track and is verified against a
real server (see Architecture.md, item 33); everything before the first request is here.
#>

. (Join-Path $PSScriptRoot 'Helpers.ps1')

BeforeAll {
    . (Join-Path $PSScriptRoot 'Helpers.ps1')
    $script:CiTools = New-CiToolsCopy -Name 'b3-tools' -Scripts @('tec-pwsh-sbom-publish.ps1')
    $sbomDir = New-ScratchDirectory -Name 'b3-sbom'
    $sbom = '{"bomFormat":"CycloneDX","specVersion":"1.6","metadata":{"timestamp":"2026-10-29T00:00:00Z","component":{"type":"application","name":"Tests","version":"main"}},"components":[]}'
    Set-Content -Path (Join-Path $sbomDir 'sbom.cdx.json') -Value $sbom -NoNewline
    $script:SbomPath = Join-Path $sbomDir 'sbom.cdx.json'

    $script:BaseSettings = @{
        DEPENDENCYTRACK_URL             = 'https://dtrack.example.com'
        DEPENDENCYTRACK_APIKEY          = '00000000-0000-0000-0000-000000000000'
        DEPENDENCYTRACK_PROJECT_VERSION = 'main'
        BUILD_REPOSITORY_NAME           = 'Tests'
    }
}

AfterAll {
    Remove-Scratch -Path $script:CiTools
    Remove-Scratch -Path (Split-Path -Parent $script:SbomPath)
}

Describe 'B3 publish, preflight fail-closed cases' {
    It 'fails when DEPENDENCYTRACK_URL is not set' {
        $r = Invoke-PublishResult -CiTools $script:CiTools -SbomPath $script:SbomPath -Environment @{
            DEPENDENCYTRACK_APIKEY = $script:BaseSettings.DEPENDENCYTRACK_APIKEY
            DEPENDENCYTRACK_PROJECT_VERSION = $script:BaseSettings.DEPENDENCYTRACK_PROJECT_VERSION
        }
        $r.ExitCode | Should -Be 1
        $r.Output | Should -Match 'DEPENDENCYTRACK_URL is not set'
    }

    It 'fails when DEPENDENCYTRACK_URL stays an unexpanded macro' {
        $r = Invoke-PublishResult -CiTools $script:CiTools -SbomPath $script:SbomPath -Environment $script:BaseSettings -Set @{
            DEPENDENCYTRACK_URL = '$(DependencyTrackUrl)' }
        $r.ExitCode | Should -Be 1
        $r.Output | Should -Match 'DEPENDENCYTRACK_URL is not set'
    }

    It 'fails when DEPENDENCYTRACK_URL is not an absolute URL' {
        $r = Invoke-PublishResult -CiTools $script:CiTools -SbomPath $script:SbomPath -Environment $script:BaseSettings -Set @{
            DEPENDENCYTRACK_URL = 'dtrack.example.com' }
        $r.ExitCode | Should -Be 1
        $r.Output | Should -Match 'DEPENDENCYTRACK_URL is not an absolute URL'
    }

    It 'fails when DEPENDENCYTRACK_URL is not https' {
        $r = Invoke-PublishResult -CiTools $script:CiTools -SbomPath $script:SbomPath -Environment $script:BaseSettings -Set @{
            DEPENDENCYTRACK_URL = 'http://dtrack.example.com' }
        $r.ExitCode | Should -Be 1
        $r.Output | Should -Match 'DEPENDENCYTRACK_URL must use https, not http'
    }

    It 'fails when DEPENDENCYTRACK_APIKEY is not set' {
        $r = Invoke-PublishResult -CiTools $script:CiTools -SbomPath $script:SbomPath -Environment @{
            DEPENDENCYTRACK_URL = $script:BaseSettings.DEPENDENCYTRACK_URL
            DEPENDENCYTRACK_PROJECT_VERSION = $script:BaseSettings.DEPENDENCYTRACK_PROJECT_VERSION
        }
        $r.ExitCode | Should -Be 1
        $r.Output | Should -Match 'DEPENDENCYTRACK_APIKEY is not set'
    }

    It 'fails when DEPENDENCYTRACK_APIKEY stays an unexpanded macro' {
        $r = Invoke-PublishResult -CiTools $script:CiTools -SbomPath $script:SbomPath -Environment $script:BaseSettings -Set @{
            DEPENDENCYTRACK_APIKEY = '$(DependencyTrackApiKey)' }
        $r.ExitCode | Should -Be 1
        $r.Output | Should -Match 'DEPENDENCYTRACK_APIKEY is not set'
    }

    It 'fails when DEPENDENCYTRACK_PROJECT_VERSION is not set' {
        $r = Invoke-PublishResult -CiTools $script:CiTools -SbomPath $script:SbomPath -Environment @{
            DEPENDENCYTRACK_URL = $script:BaseSettings.DEPENDENCYTRACK_URL
            DEPENDENCYTRACK_APIKEY = $script:BaseSettings.DEPENDENCYTRACK_APIKEY
        }
        $r.ExitCode | Should -Be 1
        $r.Output | Should -Match 'DEPENDENCYTRACK_PROJECT_VERSION is not set'
    }
}
