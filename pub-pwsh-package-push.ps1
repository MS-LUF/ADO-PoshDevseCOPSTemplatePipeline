<#
.SYNOPSIS
Pushes the packed .nupkg to the NuGet feed, on tag builds only.
.DESCRIPTION
Finds the single .nupkg packed by job C1 in the downloaded pub-pwsh-package artifact,
reads its id and version from the .nuspec inside (the archive is read only, nothing
runs), and pushes it with dotnet nuget push. The pipeline authenticates to the feed
before this script runs (the NuGetAuthenticate task, with the build identity); Azure
Artifacts takes any non-empty API key, the credential provider is the real
authentication.
The feed refuses an existing version: that failure, and any other, stops the job, so a
version is never overwritten. The version to bump is the manifest's ModuleVersion.
The .NET SDK is required on the agent for this job only.
.PARAMETER PackageFolder
Folder holding the .nupkg from the pub-pwsh-package artifact.
.PARAMETER PublishFeed
The feed to push to, as its https v3 URL: the "Connect to feed" pane of the Azure
Artifacts feed shows it (for example https://pkgs.dev.azure.com/<org>/<project>/_packaging/<feed>/nuget/v3/index.json).
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$PackageFolder,
    [string]$PublishFeed = '' # checked in the main block, so that an empty one is logged
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

# Pushes the package and stops on a non-zero exit code; without --fail-on-like behaviour
# dotnet reports a failed push (an existing version, a refused key) on its own exit code.
function Publish-CIPackage {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Package,
        [Parameter(Mandatory = $true)]
        [string]$Feed
    )

    if (-not (Get-Command dotnet -ErrorAction SilentlyContinue)) {
        throw "dotnet is not on the PATH: the .NET SDK is required on the agent for the package push."
    }
    $dotnetVersion = (& dotnet --version 2>&1 | Select-Object -First 1)
    Write-CILog -info info -message "dotnet : $dotnetVersion" -Verbose

    Write-CILog -info info -message "Pushing $([IO.Path]::GetFileName($Package)) to $Feed" -Verbose
    $output = & dotnet nuget push $Package --source $Feed --api-key AzureArtifacts 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "dotnet nuget push failed (exit $LASTEXITCODE): $($output -join [Environment]::NewLine)"
    }
    ($output | ForEach-Object { $_.ToString() }) | Where-Object { $_ } | ForEach-Object {
        Write-CILog -info info -message $_ -Verbose
    }
}

#_____________________________________________________________________________________________________
# Define log
$script:ScriptDirectory = Get-ScriptDirectory
Initialize-CILog -Prefix 'pub_pwsh_push'

#_____________________________________________________________________________________________________
$customexitcode = 0
try {
    $ErrorActionPreference = 'Stop'
    Write-CILog -info info -message "PowerShell : $($PSVersionTable.PSVersion) ($($PSVersionTable.PSEdition))" -Verbose

    if (-not (Test-Path -LiteralPath $PackageFolder -PathType Container)) {
        throw "Package folder not found: $PackageFolder."
    }
    Assert-CIPublishFeed -Value $PublishFeed
    $packages = @(Get-ChildItem -Path $PackageFolder -Filter '*.nupkg' -File)
    if ($packages.Count -ne 1) {
        throw "The pub-pwsh-package artifact holds $($packages.Count) .nupkg files, not exactly one."
    }
    $info = Get-CINupkgInfo -Path $packages[0].FullName
    Write-CILog -info info -message "Package $($info.Id) $($info.Version) ($($packages[0].Name))." -Verbose

    Publish-CIPackage -Package $packages[0].FullName -Feed $PublishFeed
    Write-CILog -info info -message "Pushed $($info.Id) $($info.Version) to $PublishFeed." -Verbose
} catch {
    $customexitcode = 1
    Write-CIFailure -Failure $_
}
exit $customexitcode
