<#
.SYNOPSIS
Checks the components of the repository under test for known vulnerabilities (CVE, GHSA) with
Grype, from the SBOM of job B1 and from the repository's lockfiles.
.DESCRIPTION
Downloads Grype at an exact version, checks its SHA-256 against the one written below and stops
on a mismatch. Grype's vulnerability database is downloaded on each run; the job stops when the
download fails or the database is more than 5 days old.
Two scans: the SBOM (PowerShell modules taken out: no advisory database covers PSGallery, and
Grype would match them against NuGet packages of the same name), and the repository folder, for
the lockfiles the SBOM does not list yet (npm, pip, Go...). The CI tooling folder is never
scanned.
A High or Critical finding that has a fix fails the job. Any other finding is a warning. A
finding covered by a valid entry of the exceptions file is accepted; an invalid entry (no exact
id or package, no reason, an expiry passed or more than a year ahead) fails the job.
The report is written to Logs/cve-report.json and Logs/cve-report.txt, with Grype's own output.
Grype and its database live in a work folder under the agent's temporary folder, removed when
the job ends, whatever its outcome.
.PARAMETER RepositoryPath
Folder of the repository under test. A pipeline that checks out several repositories
passes it; otherwise BUILD_SOURCESDIRECTORY is used, then the folder of this script.
.PARAMETER SbomPath
The SBOM written by job B1 (sbom.cdx.json).
.PARAMETER ExceptionFile
The accepted risks, relative to the repository root. The file is optional.
#>
[CmdletBinding()]
param(
    [string]$RepositoryPath = '',
    [Parameter(Mandatory = $true)]
    [string]$SbomPath,
    [string]$ExceptionFile = '.supplychain/cve-exceptions.json'
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

# Grype release and the SHA-256 of each archive, from the release's checksums file. An upgrade
# changes the version and every hash, then goes out as a release of this template.
$script:GrypeVersion = '0.121.0'
$script:GrypeHashes = @{
    'linux_amd64.tar.gz' = '64e07133d3486115de647a66581461dccf5c732748a0a3119077395565f15519'
    'linux_arm64.tar.gz' = '86f570f75ca947ea3dd6486309232bcff6d78e44ba081ae75ab14eab72be3dae'
    'darwin_amd64.tar.gz' = '27eef17e42f0340af6582cdbc33ad18faf9f601c613ab81d2e1658a94cbc357f'
    'darwin_arm64.tar.gz' = '7be39d3a0428c664ce0183e4aba31ed9accffce9eda7e7f6fa84e9c512285f27'
    'windows_amd64.zip' = 'f867bbdc14bd8b0d99b3fc47d839af07480a540072b16896373a8ba32b76f588'
}
$script:SbomPropertyPrefix = 'tec-pwsh-sbom'

# Downloads Grype for this agent's OS and architecture into $Folder, checks its hash, and returns
# the path of the executable.
function Install-CIGrype {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Folder
    )

    if ($env:OS -eq 'Windows_NT') {
        $platform = 'windows'
        $extension = 'zip'
        $executable = 'grype.exe'
    } else {
        $platform = if ((& uname -s) -eq 'Darwin') { 'darwin' } else { 'linux' }
        $extension = 'tar.gz'
        $executable = 'grype'
    }
    $architecture = if ("$([System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture)" -eq 'Arm64') { 'arm64' } else { 'amd64' }
    $assetKey = "$($platform)_$($architecture).$extension"
    if (-not $script:GrypeHashes.ContainsKey($assetKey)) {
        throw "No Grype $($script:GrypeVersion) archive is known for $assetKey."
    }
    $asset = "grype_$($script:GrypeVersion)_$assetKey"
    $archive = Join-Path $Folder $asset
    $uri = "https://github.com/anchore/grype/releases/download/v$($script:GrypeVersion)/$asset"
    Write-CILog -info info -message "Downloading $uri" -Verbose
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $savedProgress = $ProgressPreference
    $ProgressPreference = 'SilentlyContinue'
    try {
        Invoke-WebRequest -Uri $uri -OutFile $archive -UseBasicParsing
    } finally {
        $ProgressPreference = $savedProgress
    }
    $hash = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($hash -ne $script:GrypeHashes[$assetKey]) {
        throw "Grype archive $asset has SHA-256 $hash, expected $($script:GrypeHashes[$assetKey]): not run."
    }
    Write-CILog -info info -message "Grype $($script:GrypeVersion) archive verified (SHA-256 $hash)." -Verbose
    if ($extension -eq 'zip') {
        Expand-Archive -LiteralPath $archive -DestinationPath $Folder -Force
    } else {
        $tarOutput = & tar -xzf $archive -C $Folder $executable 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw "Grype archive cannot be extracted (exit $LASTEXITCODE): $($tarOutput -join [Environment]::NewLine)"
        }
    }
    Join-Path $Folder $executable
}

# Runs Grype, logs what it prints, and stops on a non-zero exit code: without --fail-on, Grype
# exits non-zero only when it cannot run (a database it cannot download, or one too old).
function Invoke-CIGrype {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Grype,
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments
    )

    $savedPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $output = & $Grype @Arguments 2>&1
        $exitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $savedPreference
    }
    foreach ($line in @($output | ForEach-Object { "$_" } | Where-Object { $_.Trim() })) {
        Write-CILog -info info -message "grype: $line" -Verbose
    }
    if ($exitCode -ne 0) {
        throw "grype $($Arguments[0]) failed (exit $exitCode)."
    }
}

# Reads and checks the exceptions file. Each entry needs an exact id (CVE or GHSA), an exact
# package name, a reason, and an expiry date (yyyy-MM-dd) from today to one year ahead. Returns
# the valid entries; each invalid one is logged and counted in $script:InvalidExceptionCount.
function Read-CICveException {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $script:InvalidExceptionCount = 0
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        Write-CILog -info info -message "No exceptions file ($ExceptionFile)." -Verbose
        return
    }
    try {
        $content = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    } catch {
        $script:InvalidExceptionCount++
        Write-CILog -info error -message "The exceptions file is not valid JSON: $($_.Exception.Message)" -Verbose
        Show-CIIssue -Type error -Message "The exceptions file is not valid JSON." -SourcePath $Path -Code 'CveException'
        return
    }
    if ($null -eq $content.exceptions) {
        $script:InvalidExceptionCount++
        Write-CILog -info error -message "The exceptions file has no 'exceptions' list." -Verbose
        Show-CIIssue -Type error -Message "The exceptions file has no 'exceptions' list." -SourcePath $Path -Code 'CveException'
        return
    }
    $today = (Get-Date).ToUniversalTime().Date
    $index = 0
    foreach ($entry in @($content.exceptions)) {
        $index++
        $problems = @()
        $id = "$($entry.id)".Trim()
        $package = "$($entry.package)".Trim()
        if ($id -notmatch '^(CVE-\d{4}-\d{4,}|GHSA(-[0-9a-z]{4}){3})$') {
            $problems += 'id must be one exact CVE or GHSA id'
        }
        if ((-not $package) -or ($package -match '[\*\?\[\]]')) {
            $problems += 'package must be one exact package name'
        }
        if (-not "$($entry.reason)".Trim()) {
            $problems += 'a reason is required'
        }
        $expires = [datetime]::MinValue
        if (-not [datetime]::TryParseExact("$($entry.expires)", 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$expires)) {
            $problems += 'expires must be a date (yyyy-MM-dd)'
        } elseif ($expires -lt $today) {
            $problems += "expired on $($entry.expires)"
        } elseif ($expires -gt $today.AddYears(1)) {
            $problems += 'expires must be at most one year ahead'
        }
        if ($problems.Count -gt 0) {
            $script:InvalidExceptionCount++
            Write-CILog -info error -message "Exception $index ($id, $package) is invalid: $($problems -join '; ')." -Verbose
            Show-CIIssue -Type error -Message "Exception $index ($id, $package) is invalid: $($problems -join '; ')." -SourcePath $Path -Code 'CveException'
            continue
        }
        [pscustomobject]@{ Id = $id; Package = $package; Reason = "$($entry.reason)".Trim(); Expires = "$($entry.expires)"; Used = $false }
    }
}

# Returns the findings of a Grype JSON report, one object per vulnerability and package version.
function Get-CIGrypeFinding {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [Parameter(Mandatory = $true)]
        [hashtable]$SbomLocations
    )

    $report = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    foreach ($match in @($report.matches)) {
        if (-not $match) {
            continue
        }
        $locations = @($match.artifact.locations | ForEach-Object { "$($_.path)".TrimStart('/') } | Where-Object { $_ })
        if (($locations.Count -eq 0) -and $match.artifact.purl -and $SbomLocations.ContainsKey("$($match.artifact.purl)")) {
            $locations = @($SbomLocations["$($match.artifact.purl)"])
        }
        [pscustomobject]@{
            Id = "$($match.vulnerability.id)"
            Aliases = @($match.relatedVulnerabilities | ForEach-Object { "$($_.id)" } | Where-Object { $_ } | Select-Object -Unique)
            Severity = "$($match.vulnerability.severity)"
            FixState = "$($match.vulnerability.fix.state)"
            FixVersions = @($match.vulnerability.fix.versions | ForEach-Object { "$_" })
            Package = "$($match.artifact.name)"
            Version = "$($match.artifact.version)"
            Type = "$($match.artifact.type)"
            Purl = "$($match.artifact.purl)"
            Locations = $locations
            Status = ''
            Exception = $null
        }
    }
}

#_____________________________________________________________________________________________________
# Define log
$script:ScriptDirectory = Get-ScriptDirectory
Initialize-CILog -Prefix 'sec_pwsh_cve'

#_____________________________________________________________________________________________________
$customexitcode = 0
$workFolder = $null
try {
    $ErrorActionPreference = 'Stop'
    $null = Initialize-CIRepository -RepositoryPath $RepositoryPath
    if (-not (Test-Path -LiteralPath $SbomPath -PathType Leaf)) {
        throw "SBOM not found: $SbomPath"
    }
    $logFolder = Split-Path -Parent $script:fulllogpath
    $exceptionPath = Join-Path $script:RepositoryRoot $ExceptionFile
    $exceptions = @(Read-CICveException -Path $exceptionPath)

    # The SBOM without its PowerShell modules, which no advisory database covers.
    $sbom = Get-Content -LiteralPath $SbomPath -Raw | ConvertFrom-Json
    $sbomLocations = @{}
    $notCheckable = New-Object 'System.Collections.Generic.List[object]'
    $checkable = New-Object 'System.Collections.Generic.List[object]'
    foreach ($component in @($sbom.components)) {
        if (-not $component) {
            continue
        }
        $componentLocations = @($component.evidence.occurrences | ForEach-Object { "$($_.location)" } | Where-Object { $_ })
        if ($component.purl) {
            $sbomLocations["$($component.purl)"] = $componentLocations
        }
        if (@($component.properties | Where-Object { $_.name -eq "$($script:SbomPropertyPrefix):ecosystem" -and $_.value -eq 'PSGallery' }).Count -gt 0) {
            $notCheckable.Add([pscustomobject]@{ Name = "$($component.name)"; Version = "$($component.version)"; Locations = $componentLocations })
        } else {
            $checkable.Add($component)
        }
    }
    foreach ($module in $notCheckable) {
        Write-CILog -info info -message "Not checkable for CVEs (PowerShell module, no advisory database): $($module.Name) $($module.Version)" -Verbose
    }

    $workFolder = Join-Path $(if ($env:AGENT_TEMPDIRECTORY) { $env:AGENT_TEMPDIRECTORY } else { [IO.Path]::GetTempPath() }) "grype-$((Get-Date).Ticks)"
    New-Item -ItemType Directory -Path $workFolder | Out-Null
    $scanSbomPath = Join-Path $workFolder 'sbom-checkable.cdx.json'
    $scanSbom = [ordered]@{
        bomFormat = 'CycloneDX'
        specVersion = "$($sbom.specVersion)"
        version = 1
        metadata = $sbom.metadata
        components = $checkable.ToArray()
    }
    [IO.File]::WriteAllText($scanSbomPath, (ConvertTo-Json -InputObject $scanSbom -Depth 20), (New-Object System.Text.UTF8Encoding $false))

    $grype = Install-CIGrype -Folder $workFolder
    $env:GRYPE_DB_CACHE_DIR = Join-Path $workFolder 'db'
    $env:GRYPE_CHECK_FOR_APP_UPDATE = 'false'
    $env:GRYPE_DB_VALIDATE_AGE = 'true'
    $env:GRYPE_DB_MAX_ALLOWED_BUILT_AGE = '120h'
    Invoke-CIGrype -Grype $grype -Arguments @('db', 'update')
    Invoke-CIGrype -Grype $grype -Arguments @('db', 'status')
    $env:GRYPE_DB_AUTO_UPDATE = 'false'

    $sbomReport = Join-Path $logFolder 'cve-grype-sbom.json'
    $folderReport = Join-Path $logFolder 'cve-grype-folder.json'
    # No -q: it would also hide why Grype failed. With no terminal, Grype prints no progress.
    Invoke-CIGrype -Grype $grype -Arguments @("sbom:$scanSbomPath", '-o', "json=$sbomReport")
    # The CI tooling folder and git's own folder are never scanned. Each pattern is one
    # --exclude=<pattern> argument: outside Windows, PowerShell expands a wildcard argument of a
    # native command that matches files (./.git/** from the repository folder), and Grype then
    # receives the files as extra arguments.
    Invoke-CIGrype -Grype $grype -Arguments @("dir:$($script:RepositoryRoot)", '--name', 'repository', '--exclude=./.git/**', '--exclude=./internal-ci/**', '-o', "json=$folderReport")

    # One finding per vulnerability and package version, from both scans.
    $findings = [ordered]@{}
    foreach ($finding in @(Get-CIGrypeFinding -Path $sbomReport -SbomLocations $sbomLocations) + @(Get-CIGrypeFinding -Path $folderReport -SbomLocations $sbomLocations)) {
        if (-not $finding) {
            continue
        }
        $key = "$($finding.Id)|$($finding.Package.ToLowerInvariant())|$($finding.Version)"
        if ($findings.Contains($key)) {
            $findings[$key].Locations = @(@($findings[$key].Locations) + @($finding.Locations) | Select-Object -Unique)
        } else {
            $findings[$key] = $finding
        }
    }

    $failingCount = 0
    foreach ($finding in $findings.Values) {
        $ids = @($finding.Id) + @($finding.Aliases)
        $exception = $exceptions | Where-Object { ($ids -contains $_.Id) -and ($_.Package -eq $finding.Package) } | Select-Object -First 1
        $fixText = if ($finding.FixVersions.Count -gt 0) { "fixed in $($finding.FixVersions -join ', ')" } else { "no fix ($($finding.FixState))" }
        $location = if ($finding.Locations.Count -gt 0) { $finding.Locations[0] } else { '' }
        $sourcePath = if ($location) { Join-Path $script:RepositoryRoot $location } else { '' }
        $message = "$($finding.Id) ($($finding.Severity)) in $($finding.Package) $($finding.Version), $fixText"
        if ($exception) {
            $exception.Used = $true
            $finding.Status = 'accepted'
            $finding.Exception = [ordered]@{ reason = $exception.Reason; expires = $exception.Expires }
            Write-CILog -info info -message "Accepted until $($exception.Expires): $message - $($exception.Reason)" -Verbose
        } elseif ((@('Critical', 'High') -contains $finding.Severity) -and ($finding.FixState -eq 'fixed')) {
            $failingCount++
            $finding.Status = 'failing'
            Write-CILog -info warning -message "$message - $location"
            Show-CIIssue -Type error -Message $message -SourcePath $sourcePath -Code $finding.Id
        } else {
            $finding.Status = 'warning'
            Write-CILog -info warning -message "$message - $location"
            Show-CIIssue -Type warning -Message $message -SourcePath $sourcePath -Code $finding.Id
        }
    }
    foreach ($exception in @($exceptions | Where-Object { -not $_.Used })) {
        Write-CILog -info info -message "Exception $($exception.Id) for $($exception.Package) matches no finding: it can be removed." -Verbose
    }

    $report = [ordered]@{
        generated = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        grype = $script:GrypeVersion
        sbom = $SbomPath
        failing = $failingCount
        invalidExceptions = $script:InvalidExceptionCount
        findings = @($findings.Values | ForEach-Object {
            [ordered]@{ id = $_.Id; aliases = @($_.Aliases); severity = $_.Severity; fixState = $_.FixState; fixVersions = @($_.FixVersions); package = $_.Package; version = $_.Version; type = $_.Type; purl = $_.Purl; locations = @($_.Locations); status = $_.Status; exception = $_.Exception }
        })
        notCheckable = @($notCheckable | ForEach-Object { [ordered]@{ name = $_.Name; version = $_.Version; locations = @($_.Locations); reason = 'PowerShell module: no advisory database covers PSGallery' } })
    }
    [IO.File]::WriteAllText((Join-Path $logFolder 'cve-report.json'), (ConvertTo-Json -InputObject $report -Depth 10), (New-Object System.Text.UTF8Encoding $false))
    $findingTable = if ($findings.Count -gt 0) {
        ($findings.Values | Select-Object Status, Id, Severity, Package, Version, @{ Name = 'Fix'; Expression = { if ($_.FixVersions.Count -gt 0) { $_.FixVersions -join ', ' } else { $_.FixState } } }, @{ Name = 'Location'; Expression = { $_.Locations -join ', ' } } | Format-Table -AutoSize | Out-String -Width 4096).Trim()
    } else {
        'No known vulnerability.'
    }
    $moduleTable = if ($notCheckable.Count -gt 0) {
        ($notCheckable | Select-Object Name, Version, @{ Name = 'Location'; Expression = { $_.Locations -join ', ' } } | Format-Table -AutoSize | Out-String -Width 4096).Trim()
    } else {
        'None.'
    }
    $text = @(
        "Known vulnerabilities - Grype $($script:GrypeVersion) - $($report.generated)"
        "Findings: $($findings.Count), failing: $failingCount, invalid exceptions: $($script:InvalidExceptionCount)"
        ''
        $findingTable
        ''
        "Not checkable for CVEs (PowerShell modules, no advisory database): $($notCheckable.Count)"
        $moduleTable
    ) -join [Environment]::NewLine
    [IO.File]::WriteAllText((Join-Path $logFolder 'cve-report.txt'), $text, (New-Object System.Text.UTF8Encoding $false))
    Write-CILog -info info -message "Findings: $($findings.Count), failing: $failingCount, accepted: $(@($findings.Values | Where-Object { $_.Status -eq 'accepted' }).Count), not checkable: $($notCheckable.Count)" -Verbose

    if (($failingCount -gt 0) -or ($script:InvalidExceptionCount -gt 0)) {
        $customexitcode = 1
        Write-CILog -info error -message "Known vulnerabilities with a fix (High or Critical), or invalid exceptions - exit job with error" -Verbose
    }
} catch {
    $customexitcode = 1
    Write-CIFailure -Failure $_
} finally {
    # Grype and its database (about 3 GB unpacked) are removed on every outcome: an agent cleans
    # its temporary folder after each job, but a local run or another tool's folder would not.
    if ($workFolder -and (Test-Path -LiteralPath $workFolder)) {
        try {
            Remove-Item -LiteralPath $workFolder -Recurse -Force -ErrorAction Stop
            Write-CILog -info info -message "Grype work folder removed: $workFolder" -Verbose
        } catch {
            Write-CILog -info warning -message "Grype work folder could not be removed ($workFolder): $($_.Exception.Message)"
        }
    }
}
exit $customexitcode
