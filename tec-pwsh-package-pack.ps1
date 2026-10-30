<#
.SYNOPSIS
Packs the module of the repository under test into a .nupkg with Publish-PSResource.
.DESCRIPTION
Finds the module manifest (.psd1) named by PackageSpec, or the single manifest at the
repository root when PackageSpec is empty. The manifest is read as data (never run) to
fail early when it has no ModuleVersion. The module folder is then copied into a staging
folder under the agent's temporary directory, without the checkout's .git (the pack must
hold the module's own files only, never the VCS internals) and without following
symlinks, and packed from that copy by the bundled Microsoft.PowerShell.PSResourceGet
into a temporary local file repository. The produced .nupkg is copied next to the log for
the pipeline to publish as the artifact pub-pwsh-package; job C2 pushes it to the feed.
The version is the manifest's ModuleVersion, the repository's own: a version already on
the feed fails the push later, it is never overwritten.
On a tag build (BUILD_SOURCEBRANCH refs/tags/...), the tag's version (the part of its name
after the last /, without an optional leading v) is compared with the packed version; a
difference is a warning, never a failure, and the package keeps the manifest's version.
The staging folder, the temporary repository and its folder are removed when the job ends,
whatever the outcome.
.PARAMETER RepositoryPath
Folder of the repository under test. A pipeline that checks out several repositories
passes it; otherwise BUILD_SOURCESDIRECTORY is used, then the folder of this script.
.PARAMETER PackageSpec
Module manifest (.psd1) to pack, relative to the repository root. Empty: the single .psd1
at the repository root is used, and there must be exactly one.
.PARAMETER PublishFeed
The feed job C2 pushes to on a tag build. Checked here, on every build, so that a missing
or non-https feed fails a PR before the merge, not the release tag's push.
.PARAMETER PSResourceGetVersion
Exact version of the bundled Microsoft.PowerShell.PSResourceGet used to pack.
#>
[CmdletBinding()]
param(
    [string]$RepositoryPath = '',
    [string]$PackageSpec = '',
    [string]$PublishFeed = '',
    [string]$PSResourceGetVersion = '1.1.0'
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

$script:PackRepoName = $null
$script:PackWorkFolder = $null
$script:PackStageFolder = $null

# Copies the module folder into a staging folder under the agent's temporary directory, so
# that the pack holds the module's own files only: the checkout's .git (VCS internals; a
# shallow one still names the remote) never goes into the .nupkg. Items named .git are
# left out at any depth, symlinks are not followed, other hidden files are copied like any
# file. The staging folder is removed in the main block's finally.
function Copy-CIModuleToStage {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ModuleFolder
    )

    $baseFolder = if ($env:AGENT_TEMPDIRECTORY) { $env:AGENT_TEMPDIRECTORY } else { [IO.Path]::GetTempPath() }
    $script:PackStageFolder = Join-Path $baseFolder "psresource-stage-$((Get-Date).Ticks)"
    Copy-CIStagedTree -Source $ModuleFolder -Destination $script:PackStageFolder
    Write-CILog -info info -message "Module folder staged at $script:PackStageFolder (without .git)." -Verbose
    $script:PackStageFolder
}

# Recursion of Copy-CIModuleToStage: creates the destination folder, then copies every
# child except the VCS internals and the links.
function Copy-CIStagedTree {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Source,
        [Parameter(Mandatory = $true)]
        [string]$Destination
    )

    New-Item -ItemType Directory -Path $Destination | Out-Null
    Get-ChildItem -LiteralPath $Source -Force -Attributes !ReparsePoint |
        Where-Object { $_.Name -ne '.git' } |
        ForEach-Object {
            $targetPath = Join-Path $Destination $_.Name
            if ($_.PSIsContainer) {
                Copy-CIStagedTree -Source $_.FullName -Destination $targetPath
            } else {
                Copy-Item -LiteralPath $_.FullName -Destination $targetPath
            }
        }
}

# Returns the file URI of a full folder path, built as text so that it is the same on every OS:
# a [uri] cast of a Linux path such as /home/vsts/... gives a relative URI with no AbsoluteUri
# (v1.6.0 and v1.6.1 C1 failed on Linux agents with an empty -Uri). Windows separators become
# slashes and a drive path gains its leading slash: file:///C:/... and file:///home/....
function ConvertTo-CIFileUri {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $uriPath = $Path.Replace([IO.Path]::DirectorySeparatorChar, '/').Replace([IO.Path]::AltDirectorySeparatorChar, '/')
    if (-not $uriPath.StartsWith('/')) {
        $uriPath = '/' + $uriPath
    }
    $uri = $null
    if (-not [uri]::TryCreate('file://' + $uriPath, [UriKind]::Absolute, [ref]$uri) -or -not $uri.IsFile) {
        throw "No file URI can be built for the temporary repository folder $Path."
    }
    $uri.AbsoluteUri
}

# Registers a temporary local file repository and creates its folder; both are removed in
# the main block's finally. The repository name is kept only once it is registered, so that
# the cleanup does not try to unregister a repository that never was.
function Initialize-CIPackRepository {
    $baseFolder = if ($env:AGENT_TEMPDIRECTORY) { $env:AGENT_TEMPDIRECTORY } else { [IO.Path]::GetTempPath() }
    $script:PackWorkFolder = Join-Path $baseFolder "psresource-pack-$((Get-Date).Ticks)"
    New-Item -ItemType Directory -Path $script:PackWorkFolder | Out-Null
    $repositoryName = "ci-pack-$((Get-Date).Ticks)"
    $repositoryUri = ConvertTo-CIFileUri -Path ([IO.Path]::GetFullPath($script:PackWorkFolder))
    Register-PSResourceRepository -Name $repositoryName -Uri $repositoryUri
    $script:PackRepoName = $repositoryName
    Write-CILog -info info -message "Packing into temporary repository $script:PackRepoName ($repositoryUri)." -Verbose
}

# Returns a NuGet version as a comparable key: four numeric parts (missing ones are 0, so
# 1.2.3 and 1.2.3.0 match, as NuGet normalizes them) and the prerelease label in lower case
# (NuGet compares it case-insensitively); build metadata after + is ignored. $null when the
# text is not a version.
function ConvertTo-CIVersionKey {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Version
    )

    if ($Version -notmatch '^(\d+)(\.\d+){0,3}(-[0-9A-Za-z.-]+)?(\+[0-9A-Za-z.-]+)?$') {
        return $null
    }
    $release = ($Version -split '[-+]', 2)[0]
    $label = if ($Version -match '^[^-+]*-([^+]+)') { $Matches[1].ToLowerInvariant() } else { '' }
    $numbers = @($release.Split('.') | ForEach-Object { [long]$_ })
    while ($numbers.Count -lt 4) {
        $numbers += 0
    }
    "$($numbers -join '.')|$label"
}

# On a tag build, warns when the tag's version differs from the packed version; it never stops
# the job (the owner's choice, backlog item 36): the package keeps the manifest's version. The
# tag's version is the part of its name after the last / without an optional leading v, so
# v1.2.3, 1.2.3, release/1.2.3 and <module>/1.2.3 all name 1.2.3 (a NuGet version holds no /).
function Test-CITagVersion {
    param(
        [Parameter(Mandatory = $true)]
        [string]$PackageVersion
    )

    $sourceBranch = "$($env:BUILD_SOURCEBRANCH)"
    if (-not $sourceBranch.StartsWith('refs/tags/')) {
        return
    }
    $tagName = $sourceBranch.Substring('refs/tags/'.Length)
    $tagVersion = ($tagName -split '/')[-1] -replace '^[vV]', ''
    $tagKey = ConvertTo-CIVersionKey -Version $tagVersion
    $packageKey = ConvertTo-CIVersionKey -Version $PackageVersion
    if (-not $tagKey) {
        $message = "The tag $tagName does not name a version: the package is published as $PackageVersion, the manifest's version."
    } elseif ($tagKey -ne $packageKey) {
        $message = "The tag $tagName names version $tagVersion, but the package is published as $PackageVersion, the manifest's version: bump ModuleVersion or rename the tag."
    } else {
        Write-CILog -info info -message "The tag $tagName matches the package version $PackageVersion." -Verbose
        return
    }
    Write-CILog -info warning -message $message -Verbose
    Show-CIIssue -Type warning -Message $message -Code 'TagVersion'
}

# Packs the staged module folder into the temporary repository. Dependencies are not
# checked against it: it is empty, and the dependencies stay recorded in the package.
function Publish-CIPackage {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ModuleFolder
    )

    Publish-PSResource -Path $ModuleFolder -Repository $script:PackRepoName -SkipDependenciesCheck
}

#_____________________________________________________________________________________________________
# Define log
$script:ScriptDirectory = Get-ScriptDirectory
Initialize-CILog -Prefix 'tec_pwsh_pack'

#_____________________________________________________________________________________________________
$customexitcode = 0
try {
    $ErrorActionPreference = 'Stop'
    $null = Initialize-CIRepository -RepositoryPath $RepositoryPath
    Assert-CIPublishFeed -Value $PublishFeed

    # The manifest to pack: named by PackageSpec, or the single one at the repository root.
    # The root is compared with a trailing separator, so that a sibling folder whose name
    # starts with the root's (self2 next to self) does not pass.
    if ($PackageSpec) {
        $manifestRelative = $PackageSpec
        $manifestFullPath = [IO.Path]::GetFullPath((Join-Path $script:RepositoryRoot $manifestRelative))
        $rootPrefix = [IO.Path]::GetFullPath($script:RepositoryRoot).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
        if (-not $manifestFullPath.StartsWith($rootPrefix)) {
            throw "PackageSpec escapes the repository: $PackageSpec."
        }
        if ([IO.Path]::GetExtension($manifestRelative) -ne '.psd1') {
            throw "PackageSpec is not a .psd1 manifest: $PackageSpec."
        }
        if (-not (Test-Path -LiteralPath $manifestFullPath -PathType Leaf)) {
            throw "PackageSpec not found in the checkout: $manifestRelative."
        }
    } else {
        $rootManifests = @(Get-ChildItem -Path $script:RepositoryRoot -Filter '*.psd1' -File)
        if ($rootManifests.Count -ne 1) {
            throw "PackageSpec is empty and the repository root holds $($rootManifests.Count) .psd1 files, not exactly one: set the packageSpec parameter."
        }
        $manifestRelative = $rootManifests[0].Name
        $manifestFullPath = $rootManifests[0].FullName
    }
    Write-CILog -info info -message "Packing manifest: $manifestRelative" -Verbose

    # Read as data, never run: no ModuleVersion means no version to publish with.
    try {
        $manifest = Import-PowerShellDataFile -LiteralPath $manifestFullPath
    } catch {
        throw "$manifestRelative cannot be read as a data file: $($_.Exception.Message)"
    }
    if (-not $manifest.ModuleVersion) {
        throw "$manifestRelative has no ModuleVersion: the package version is the manifest's, and there is none."
    }
    Write-CILog -info info -message "Manifest version: $($manifest.ModuleVersion)" -Verbose

    Import-CIModule -Name 'Microsoft.PowerShell.PSResourceGet' -Version $PSResourceGetVersion

    # The pack runs on the staging copy: the checkout's .git never goes into the .nupkg.
    $moduleFolder = Split-Path -Parent $manifestFullPath
    $stagedFolder = Copy-CIModuleToStage -ModuleFolder $moduleFolder
    Initialize-CIPackRepository
    Publish-CIPackage -ModuleFolder $stagedFolder

    $packages = @(Get-ChildItem -Path $script:PackWorkFolder -Filter '*.nupkg' -File)
    if ($packages.Count -ne 1) {
        throw "Packing produced $($packages.Count) .nupkg files, not exactly one."
    }
    $info = Get-CINupkgInfo -Path $packages[0].FullName
    Write-CILog -info info -message "Packed $($info.Id) $($info.Version) ($($packages[0].Name))." -Verbose
    Test-CITagVersion -PackageVersion $info.Version

    $packagePath = Join-Path (Split-Path -Parent $script:fulllogpath) $packages[0].Name
    Copy-Item -LiteralPath $packages[0].FullName -Destination $packagePath
    Write-CILog -info info -message "Package written: $packagePath" -Verbose
} catch {
    $customexitcode = 1
    Write-CIFailure -Failure $_
} finally {
    if ($script:PackRepoName) {
        try {
            Unregister-PSResourceRepository -Name $script:PackRepoName -ErrorAction Stop
        } catch {
            Write-CILog -info warning -message "Temporary repository $($script:PackRepoName) could not be unregistered: $($_.Exception.Message)" -Verbose
        }
    }
    if ($script:PackStageFolder -and (Test-Path -LiteralPath $script:PackStageFolder)) {
        Remove-Item -LiteralPath $script:PackStageFolder -Recurse -Force
    }
    if ($script:PackWorkFolder -and (Test-Path -LiteralPath $script:PackWorkFolder)) {
        Remove-Item -LiteralPath $script:PackWorkFolder -Recurse -Force
    }
}
exit $customexitcode
