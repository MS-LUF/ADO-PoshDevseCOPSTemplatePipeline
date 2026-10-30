<#
.SYNOPSIS
Publishes the SBOM of job B1 to a Dependency-Track server.
.DESCRIPTION
Uploads the SBOM (PUT /api/v1/bom, the BOM in Base64) to the project named after the repository,
at the version named after the base branch, creating the project when it does not exist
(autoCreate) and marking that version as the latest. Then waits until Dependency-Track has
processed it (GET /api/v1/event/token/{token}), up to a timeout.
The server, the key and the project come from environment variables, never from the command
line, so that no value is parsed as PowerShell in the process that holds the key:
- DEPENDENCYTRACK_URL: the API server's base URL (https only), without /api;
- DEPENDENCYTRACK_APIKEY: an API key with BOM_UPLOAD and PROJECT_CREATION_UPLOAD;
- DEPENDENCYTRACK_PROJECT_NAME: the project; empty, the repository's name (BUILD_REPOSITORY_NAME);
- DEPENDENCYTRACK_PROJECT_VERSION: the project version (the base branch's name);
- DEPENDENCYTRACK_PROJECT_TAG: a tag given to the project when it is created (optional).
The key is never written to the log or the console. Any error fails the job: an unreachable
server, a rejected SBOM, a refused key, a processing that does not end before the timeout.
.PARAMETER SbomPath
The SBOM written by job B1 (sbom.cdx.json).
.PARAMETER TimeoutSeconds
How long to wait for Dependency-Track to process the SBOM.
.PARAMETER PollSeconds
The interval between two checks of the processing.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$SbomPath,
    [int]$TimeoutSeconds = 300,
    [int]$PollSeconds = 5
)

#_____________________________________________________________________________________________________
# Define functions: shared by the CI scripts, in pwsh-ci-common.ps1 next to them
$commonScript = Join-Path $PSScriptRoot 'pwsh-ci-common.ps1'
if (-not (Test-Path -LiteralPath $commonScript -PathType Leaf)) {
    Write-Error -Message "Shared CI code not found: $commonScript" -ErrorAction Continue
    exit 1
}
. $commonScript

#_____________________________________________________________________________________________________
# Define functions: this job only

# The PUT endpoint refuses a Base64 BOM longer than this (Dependency-Track's documented limit).
$script:MaxBomBase64Length = 20000000

# Returns an environment variable of the pipeline, or stops when it is missing. An Azure Pipelines
# macro whose variable is not defined stays as its own text, "$(Name)": that is missing too.
function Get-CISetting {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,
        [switch]$Optional
    )

    $value = [Environment]::GetEnvironmentVariable($Name)
    if ($value -and $value.StartsWith('$(')) {
        $value = ''
    }
    if (-not $value -and -not $Optional) {
        throw "$Name is not set: the variable group must define it (see the README)."
    }
    "$value".Trim()
}

# Returns the base URL of the Dependency-Track API server, without a trailing slash. Only https
# is accepted: the key travels in a request header.
function Get-CIDependencyTrackUrl {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Value
    )

    $uri = $null
    if (-not [uri]::TryCreate($Value, [UriKind]::Absolute, [ref]$uri)) {
        throw "DEPENDENCYTRACK_URL is not an absolute URL."
    }
    if ($uri.Scheme -ne 'https') {
        throw "DEPENDENCYTRACK_URL must use https, not $($uri.Scheme): the API key is sent with each request."
    }
    $Value.TrimEnd('/')
}

# Calls the Dependency-Track API and returns its JSON answer. A refusal (4xx, 5xx) or a network
# error stops the job, with the status and the server's message, never the key.
function Invoke-CIDependencyTrack {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('Get', 'Put')]
        [string]$Method,
        [Parameter(Mandatory = $true)]
        [string]$Uri,
        [Parameter(Mandatory = $true)]
        [string]$ApiKey,
        [byte[]]$Body
    )

    $request = @{
        Method = $Method
        Uri = $Uri
        Headers = @{ 'X-Api-Key' = $ApiKey; 'Accept' = 'application/json' }
        TimeoutSec = 120
        UseBasicParsing = $true
    }
    if ($Body) {
        $request.ContentType = 'application/json'
        $request.Body = $Body
    }
    try {
        Invoke-RestMethod @request
    } catch {
        $status = $null
        if ($_.Exception.Response) {
            $status = [int]$_.Exception.Response.StatusCode
        }
        $detail = if ($_.ErrorDetails -and $_.ErrorDetails.Message) { $_.ErrorDetails.Message } else { $_.Exception.Message }
        if ($detail.Length -gt 2000) {
            $detail = $detail.Substring(0, 2000) + '...'
        }
        $reason = switch ($status) {
            401 { 'the API key was refused' }
            403 { 'the API key lacks a permission (BOM_UPLOAD, and PROJECT_CREATION_UPLOAD for a new project)' }
            400 { 'the SBOM or the request was rejected' }
            404 { 'the project or the endpoint was not found' }
            default { 'the request failed' }
        }
        $statusText = if ($status) { "HTTP $status" } else { 'no answer' }
        throw "Dependency-Track $Method $Uri ($statusText): $reason. $detail"
    }
}

#_____________________________________________________________________________________________________
# Define log
$script:ScriptDirectory = Get-ScriptDirectory
Initialize-CILog -Prefix 'tec_pwsh_sbom_publish'

#_____________________________________________________________________________________________________
$customexitcode = 0
try {
    $ErrorActionPreference = 'Stop'
    if ($TimeoutSeconds -lt 1 -or $PollSeconds -lt 1) {
        throw "TimeoutSeconds and PollSeconds must be at least 1."
    }
    $baseUrl = Get-CIDependencyTrackUrl -Value (Get-CISetting -Name 'DEPENDENCYTRACK_URL')
    $apiKey = Get-CISetting -Name 'DEPENDENCYTRACK_APIKEY'
    $projectName = Get-CISetting -Name 'DEPENDENCYTRACK_PROJECT_NAME' -Optional
    if (-not $projectName) {
        $projectName = Get-CISetting -Name 'BUILD_REPOSITORY_NAME'
    }
    $projectVersion = Get-CISetting -Name 'DEPENDENCYTRACK_PROJECT_VERSION'
    $projectTag = Get-CISetting -Name 'DEPENDENCYTRACK_PROJECT_TAG' -Optional

    if (-not (Test-Path -LiteralPath $SbomPath -PathType Leaf)) {
        throw "SBOM not found: $SbomPath"
    }
    $sbomText = [IO.File]::ReadAllText($SbomPath)
    $sbom = $sbomText | ConvertFrom-Json
    if ($sbom.bomFormat -ne 'CycloneDX') {
        throw "Not a CycloneDX SBOM: $SbomPath"
    }
    $bomBase64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($sbomText))
    if ($bomBase64.Length -gt $script:MaxBomBase64Length) {
        throw "The SBOM is too large for Dependency-Track's upload ($($bomBase64.Length) Base64 characters, at most $($script:MaxBomBase64Length))."
    }

    # Windows PowerShell 5.1 may still offer TLS 1.0 first, which current servers refuse.
    if ($PSVersionTable.PSVersion.Major -lt 6) {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    }

    Write-CILog -info info -message "Dependency-Track server: $baseUrl" -Verbose
    Write-CILog -info info -message "Project: $projectName, version $projectVersion$(if ($projectTag) { ", tag $projectTag (applied when the project is created)" })" -Verbose
    Write-CILog -info info -message "SBOM: $SbomPath ($(@($sbom.components).Count) components, serial number $($sbom.serialNumber))" -Verbose

    $request = [ordered]@{
        projectName = $projectName
        projectVersion = $projectVersion
        autoCreate = $true
        isLatest = $true
        bom = $bomBase64
    }
    if ($projectTag) {
        $request.projectTags = @(@{ name = $projectTag })
    }
    $body = [Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject $request -Depth 5 -Compress))
    $upload = Invoke-CIDependencyTrack -Method Put -Uri "$baseUrl/api/v1/bom" -ApiKey $apiKey -Body $body

    $token = "$($upload.token)"
    $tokenGuid = [guid]::Empty
    if (-not [guid]::TryParse($token, [ref]$tokenGuid)) {
        throw "Dependency-Track accepted the SBOM but returned no processing token."
    }
    Write-CILog -info info -message "SBOM accepted, processing token $tokenGuid$(if ($upload.project) { ", project $($upload.project)" })" -Verbose

    # Dependency-Track processes the SBOM asynchronously: wait until the token's work is done.
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $processing = $true
    while ($processing) {
        $status = Invoke-CIDependencyTrack -Method Get -Uri "$baseUrl/api/v1/event/token/$tokenGuid" -ApiKey $apiKey
        if ($status.processing -eq $false) {
            $processing = $false
        } elseif ((Get-Date) -ge $deadline) {
            throw "Dependency-Track did not finish processing the SBOM within $TimeoutSeconds s (token $tokenGuid)."
        } else {
            Start-Sleep -Seconds $PollSeconds
        }
    }
    Write-CILog -info info -message "SBOM processed by Dependency-Track: $projectName $projectVersion." -Verbose
} catch {
    $customexitcode = 1
    Write-CIFailure -Failure $_
}
exit $customexitcode
