<#
.SYNOPSIS
Tests for job B3, tec-pwsh-sbom-publish.ps1: preflight checks that need no server.
.DESCRIPTION
The happy path (a real upload) needs an https Dependency-Track and is verified against a
real server (backlog item 33); everything before the first request is here.
#>

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

Describe 'B3 publish, against a stand-in for the server' {
    BeforeAll {
        # Replaces Invoke-RestMethod in the job's process: https stays required, no real request
        # is made. It records what it receives, and answers according to STUB_MODE.
        $script:Prelude = @'
$global:StubPolls = 0
function global:Invoke-RestMethod {
    param($Method, $Uri, $Headers, $TimeoutSec, [switch]$UseBasicParsing, $ContentType, $Body)
    Add-Content -LiteralPath $env:STUB_RECORD -Value "$Method $Uri key=$($Headers['X-Api-Key'])"
    $mode = $env:STUB_MODE
    if ($mode -eq 'refused') {
        $failure = [Exception]::new('Unauthorized')
        Add-Member -InputObject $failure -NotePropertyName Response -NotePropertyValue ([pscustomobject]@{ StatusCode = 401 })
        throw $failure
    }
    if ($Method -eq 'Put') {
        if ($mode -eq 'notoken') { return [pscustomobject]@{} }
        return [pscustomobject]@{ token = '11111111-1111-1111-1111-111111111111' }
    }
    $global:StubPolls++
    return [pscustomobject]@{ processing = ($mode -eq 'never' -or $global:StubPolls -lt 2) }
}
'@
        $script:StubKey = 'stub-key-must-never-be-printed'

        function Invoke-StubbedPublish {
            param([string]$Mode, [string]$Arguments = '-PollSeconds 1')
            $tools = New-CiToolsCopy -Name 'b3-stub-tools' -Scripts @('tec-pwsh-sbom-publish.ps1')
            $wrapper = New-TaskWrapper -CiTools $tools -ScriptName 'tec-pwsh-sbom-publish.ps1' -Prelude $script:Prelude -Arguments "-SbomPath `$env:CI_SBOM $Arguments"
            $record = Join-Path $tools 'stub-record.txt'
            $r = Invoke-JobScript -CiTools $tools -ScriptName $wrapper -Environment @{
                CI_SBOM                         = $script:SbomPath
                STUB_MODE                       = $Mode
                STUB_RECORD                     = $record
                DEPENDENCYTRACK_URL             = 'https://dtrack.example.com'
                DEPENDENCYTRACK_APIKEY          = $script:StubKey
                DEPENDENCYTRACK_PROJECT_VERSION = 'main'
                BUILD_REPOSITORY_NAME           = 'Tests'
            }
            [pscustomobject]@{
                ExitCode = $r.ExitCode
                Output   = $r.Output
                Record   = @(Get-Content -LiteralPath $record -ErrorAction SilentlyContinue)
                Log      = (Get-CiLog -CiTools $tools -Raw) -join "`n"
                Tools    = $tools
            }
        }
    }

    It 'uploads, polls until the processing ends, and passes' {
        $r = Invoke-StubbedPublish -Mode 'ok'
        try {
            $r.ExitCode | Should -Be 0
            $r.Record[0] | Should -Be "Put https://dtrack.example.com/api/v1/bom key=$($script:StubKey)"
            $r.Record.Count | Should -Be 3
            $r.Record[1] | Should -BeLike 'Get https://dtrack.example.com/api/v1/event/token/*'
        } finally { Remove-Scratch -Path $r.Tools }
    }

    It 'fails with the reason on <Mode>' -ForEach @(
        @{ Mode = 'refused'; Reason = 'the API key was refused' }
        @{ Mode = 'notoken'; Reason = 'no processing token' }
        @{ Mode = 'never'; Reason = 'did not finish processing' }
    ) {
        $r = Invoke-StubbedPublish -Mode $Mode -Arguments '-PollSeconds 1 -TimeoutSeconds 1'
        try {
            $r.ExitCode | Should -Be 1
            $r.Log | Should -Match $Reason
        } finally { Remove-Scratch -Path $r.Tools }
    }

    It 'never prints or logs the key, on <Mode>' -ForEach @(
        @{ Mode = 'ok' }
        @{ Mode = 'refused' }
    ) {
        $r = Invoke-StubbedPublish -Mode $Mode
        try {
            $r.Record[0] | Should -Match $script:StubKey
            $r.Output | Should -Not -Match $script:StubKey
            $r.Log | Should -Not -Match $script:StubKey
        } finally { Remove-Scratch -Path $r.Tools }
    }
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
