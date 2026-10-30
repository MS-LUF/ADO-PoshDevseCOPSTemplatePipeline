<#
.SYNOPSIS
Writes the software bill of materials (SBOM) of the repository under test, as CycloneDX 1.6 JSON.
.DESCRIPTION
Inventories the files of the tested commit (git ls-files; the CI tooling folder is never
included):
- the PowerShell modules the repository declares: RequiredModules and NestedModules of each
  .psd1, and #Requires -Modules of each .ps1 and .psm1;
- the repository's own modules: each .psd1 with a ModuleVersion;
- the .dll and .exe files, with their SHA-256: a .NET assembly is named after its assembly name,
  which is usually its NuGet ID, and versioned from its product version;
- the NuGet packages of each packages.lock.json.
Nothing from the branch is run: .psd1 files are read as data (Import-PowerShellDataFile),
scripts are parsed, assemblies are read for their metadata only.
The SBOM is written to Logs/sbom.cdx.json. The job fails only on its own errors: a module
without an exact version and a binary with no NuGet ID are warnings.
.PARAMETER RepositoryPath
Folder of the repository under test. A pipeline that checks out several repositories
passes it; otherwise BUILD_SOURCESDIRECTORY is used, then the folder of this script.
.PARAMETER TemplateRef
Ref of this template the pipeline runs (its release tag), recorded as the SBOM tool's version.
#>
[CmdletBinding()]
param(
    [string]$RepositoryPath = '',
    [string]$TemplateRef = ''
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

# Components of the SBOM, keyed by their bom-ref, and the dependencies of each bom-ref.
$script:SbomComponents = New-Object 'System.Collections.Specialized.OrderedDictionary'
$script:SbomDependencies = New-Object 'System.Collections.Specialized.OrderedDictionary'
$script:SbomPropertyPrefix = 'tec-pwsh-sbom'
$script:PSGalleryFeed = 'https://www.powershellgallery.com/api/v2'

function Get-SbomFileHash {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    # The leading comma keeps the one-item array an array: CycloneDX needs a list of hashes.
    , @([ordered]@{ alg = 'SHA-256'; content = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() })
}

function Add-SbomDependency {
    param(
        [Parameter(Mandatory = $true)]
        [string]$From,
        [Parameter(Mandatory = $true)]
        [string]$To
    )

    if (-not $script:SbomDependencies.Contains($From)) {
        $script:SbomDependencies[$From] = New-Object 'System.Collections.Generic.List[string]'
    }
    if (-not $script:SbomDependencies[$From].Contains($To)) {
        $script:SbomDependencies[$From].Add($To)
    }
}

# Adds a PowerShell module dependency (a name, or a module specification with its versions) found
# in a file of the repository, and returns its bom-ref. A module without an exact version is a
# warning: the SBOM cannot say which version runs.
function Add-SbomModuleDependency {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,
        [string]$RequiredVersion,
        [string]$MinimumVersion,
        [string]$MaximumVersion,
        [Parameter(Mandatory = $true)]
        [string]$FoundIn
    )

    $nameReference = [uri]::EscapeDataString($Name)
    if ($RequiredVersion) {
        $bomRef = "pkg:nuget/$nameReference@$([uri]::EscapeDataString($RequiredVersion))?repository_url=$($script:PSGalleryFeed)"
    } else {
        $bomRef = "psmodule:$Name|$MinimumVersion|$MaximumVersion"
    }
    if (-not $script:SbomComponents.Contains($bomRef)) {
        $component = [ordered]@{ type = 'library'; 'bom-ref' = $bomRef; name = $Name }
        $properties = @(
            [ordered]@{ name = "$($script:SbomPropertyPrefix):ecosystem"; value = 'PSGallery' }
            [ordered]@{ name = "$($script:SbomPropertyPrefix):kind"; value = 'module-dependency' }
        )
        if ($RequiredVersion) {
            $component.version = $RequiredVersion
            $component.purl = $bomRef
        } else {
            if ($MinimumVersion) { $properties += [ordered]@{ name = "$($script:SbomPropertyPrefix):minimumVersion"; value = $MinimumVersion } }
            if ($MaximumVersion) { $properties += [ordered]@{ name = "$($script:SbomPropertyPrefix):maximumVersion"; value = $MaximumVersion } }
            Write-CILog -info warning -message "Module $Name has no exact version (in $FoundIn): the SBOM cannot name the version that runs."
            Show-CIIssue -Type warning -Message "Module $Name has no exact version (RequiredVersion): the SBOM cannot name the version that runs." -SourcePath (Join-Path $script:RepositoryRoot $FoundIn) -Code 'SbomModuleVersion'
        }
        $component.properties = $properties
        $component.evidence = [ordered]@{ occurrences = (New-Object 'System.Collections.Generic.List[object]') }
        $script:SbomComponents[$bomRef] = $component
    }
    $occurrences = $script:SbomComponents[$bomRef].evidence.occurrences
    if (-not ($occurrences | Where-Object { $_.location -eq $FoundIn })) {
        $occurrences.Add([ordered]@{ location = $FoundIn })
    }
    $bomRef
}

# Turns one RequiredModules or NestedModules entry into a module dependency. A string is a module
# name; a hashtable is a module specification. A nested module given as a path, or found next to
# the manifest, belongs to the module itself and is not a dependency.
function ConvertFrom-SbomModuleEntry {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Entry,
        [Parameter(Mandatory = $true)]
        [string]$ManifestFile,
        [switch]$Nested
    )

    if ($Entry -is [hashtable]) {
        if (-not $Entry.ModuleName) {
            Write-CILog -info warning -message "A module entry without ModuleName in $ManifestFile is skipped."
            return
        }
        Add-SbomModuleDependency -Name "$($Entry.ModuleName)" -RequiredVersion "$($Entry.RequiredVersion)" -MinimumVersion "$($Entry.ModuleVersion)" -MaximumVersion "$($Entry.MaximumVersion)" -FoundIn $ManifestFile
        return
    }
    $name = "$Entry"
    if (-not $name) {
        return
    }
    if ($Nested) {
        $manifestFolder = Split-Path -Parent (Join-Path $script:RepositoryRoot $ManifestFile)
        if (($name -match '[\\/]') -or ($name -match '\.(ps1|psm1|psd1|dll|cdxml|xaml)$') -or (Test-Path -LiteralPath (Join-Path $manifestFolder $name))) {
            return
        }
    }
    Add-SbomModuleDependency -Name $name -FoundIn $ManifestFile
}

# Reads a .psd1 as data, adds the module it describes (when it has a ModuleVersion) and its module
# dependencies. A manifest that cannot be read as data is a warning, not a failure.
function Add-SbomManifest {
    param(
        [Parameter(Mandatory = $true)]
        [string]$File
    )

    $path = Join-Path $script:RepositoryRoot $File
    try {
        $manifest = Import-PowerShellDataFile -LiteralPath $path
    } catch {
        Write-CILog -info warning -message "$File cannot be read as a data file, so its modules are not in the SBOM: $($_.Exception.Message)"
        Show-CIIssue -Type warning -Message "Cannot be read as a data file, so its modules are not in the SBOM." -SourcePath $path -Code 'SbomManifest'
        return
    }

    $owner = 'root'
    if ($manifest.ModuleVersion) {
        $name = [IO.Path]::GetFileNameWithoutExtension($File)
        $owner = "file:$File"
        $component = [ordered]@{
            type = 'library'
            'bom-ref' = $owner
            name = $name
            version = "$($manifest.ModuleVersion)"
            purl = "pkg:nuget/$([uri]::EscapeDataString($name))@$([uri]::EscapeDataString("$($manifest.ModuleVersion)"))?repository_url=$($script:PSGalleryFeed)"
            hashes = Get-SbomFileHash -Path $path
        }
        if ($manifest.Author -or $manifest.CompanyName) {
            $component.supplier = [ordered]@{ name = "$(if ($manifest.CompanyName) { $manifest.CompanyName } else { $manifest.Author })" }
        }
        if ($manifest.Description) {
            $component.description = "$($manifest.Description)"
        }
        if ($manifest.PrivateData -and $manifest.PrivateData.PSData -and $manifest.PrivateData.PSData.LicenseUri) {
            $component.licenses = @([ordered]@{ license = [ordered]@{ url = "$($manifest.PrivateData.PSData.LicenseUri)" } })
        }
        $component.properties = @(
            [ordered]@{ name = "$($script:SbomPropertyPrefix):ecosystem"; value = 'PSGallery' }
            [ordered]@{ name = "$($script:SbomPropertyPrefix):kind"; value = 'module' }
            [ordered]@{ name = "$($script:SbomPropertyPrefix):path"; value = $File }
        )
        $component.evidence = [ordered]@{ occurrences = @([ordered]@{ location = $File }) }
        $script:SbomComponents[$owner] = $component
        Add-SbomDependency -From 'root' -To $owner
        Write-CILog -info info -message "Module $name $($manifest.ModuleVersion) ($File)" -Verbose
    }
    foreach ($entry in @($manifest.RequiredModules)) {
        if ($null -ne $entry) {
            $reference = ConvertFrom-SbomModuleEntry -Entry $entry -ManifestFile $File
            if ($reference) { Add-SbomDependency -From $owner -To $reference }
        }
    }
    foreach ($entry in @($manifest.NestedModules)) {
        if ($null -ne $entry) {
            $reference = ConvertFrom-SbomModuleEntry -Entry $entry -ManifestFile $File -Nested
            if ($reference) { Add-SbomDependency -From $owner -To $reference }
        }
    }
}

# Adds the modules of the #Requires -Modules lines of a script. The script is parsed, not run.
function Add-SbomScriptRequirement {
    param(
        [Parameter(Mandatory = $true)]
        [string]$File
    )

    $tokens = $null
    $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $script:RepositoryRoot $File), [ref]$tokens, [ref]$parseErrors)
    if (-not $ast.ScriptRequirements) {
        return
    }
    foreach ($module in @($ast.ScriptRequirements.RequiredModules)) {
        $reference = Add-SbomModuleDependency -Name $module.Name -RequiredVersion "$($module.RequiredVersion)" -MinimumVersion "$($module.Version)" -MaximumVersion "$($module.MaximumVersion)" -FoundIn $File
        Add-SbomDependency -From 'root' -To $reference
    }
}

# Adds a .dll or .exe with its hash. A .NET assembly is read for its metadata only (never loaded to
# run): its assembly name, usually its NuGet ID, and its product version without the build
# metadata ("13.0.4+4e13299" -> "13.0.4"). Any other binary is listed with its hash, as a warning.
function Add-SbomBinary {
    param(
        [Parameter(Mandatory = $true)]
        [string]$File
    )

    $path = Join-Path $script:RepositoryRoot $File
    $bomRef = "file:$File"
    $component = [ordered]@{ type = 'library'; 'bom-ref' = $bomRef; name = [IO.Path]::GetFileName($File) }
    $assemblyName = $null
    try {
        $assemblyName = [System.Reflection.AssemblyName]::GetAssemblyName($path)
    } catch {
        $assemblyName = $null
    }
    if ($assemblyName) {
        $versionInfo = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($path)
        $version = "$($versionInfo.ProductVersion)".Split('+')[0].Trim()
        if (-not $version) {
            $version = "$($assemblyName.Version)"
        }
        $component.name = $assemblyName.Name
        $component.version = $version
        $component.purl = "pkg:nuget/$([uri]::EscapeDataString($assemblyName.Name))@$([uri]::EscapeDataString($version))"
        if ($versionInfo.CompanyName) {
            $component.supplier = [ordered]@{ name = "$($versionInfo.CompanyName)" }
        }
        $identification = 'assembly-name'
        Write-CILog -info info -message "Assembly $($assemblyName.Name) $version ($File)" -Verbose
    } else {
        $component.type = 'file'
        $identification = 'none'
        Write-CILog -info warning -message "$File is not a .NET assembly: no NuGet ID, so it is listed with its hash only and not checked for CVEs."
        Show-CIIssue -Type warning -Message "Not a .NET assembly: no NuGet ID, so it is listed with its hash only and not checked for CVEs." -SourcePath $path -Code 'SbomBinary'
    }
    $component.hashes = Get-SbomFileHash -Path $path
    $component.properties = @(
        [ordered]@{ name = "$($script:SbomPropertyPrefix):kind"; value = 'binary' }
        [ordered]@{ name = "$($script:SbomPropertyPrefix):identification"; value = $identification }
        [ordered]@{ name = "$($script:SbomPropertyPrefix):path"; value = $File }
    )
    $component.evidence = [ordered]@{ occurrences = @([ordered]@{ location = $File }) }
    $script:SbomComponents[$bomRef] = $component
    Add-SbomDependency -From 'root' -To $bomRef
}

# Adds the NuGet packages of a packages.lock.json (every target framework; project references are
# skipped: they are the repository's own code).
function Add-SbomNuGetLock {
    param(
        [Parameter(Mandatory = $true)]
        [string]$File
    )

    $lock = Get-Content -LiteralPath (Join-Path $script:RepositoryRoot $File) -Raw | ConvertFrom-Json
    if (-not $lock.dependencies) {
        return
    }
    foreach ($framework in $lock.dependencies.PSObject.Properties) {
        foreach ($package in $framework.Value.PSObject.Properties) {
            if (($package.Value.type -eq 'Project') -or (-not $package.Value.resolved)) {
                continue
            }
            $bomRef = "pkg:nuget/$([uri]::EscapeDataString($package.Name))@$([uri]::EscapeDataString("$($package.Value.resolved)"))"
            if (-not $script:SbomComponents.Contains($bomRef)) {
                $script:SbomComponents[$bomRef] = [ordered]@{
                    type = 'library'
                    'bom-ref' = $bomRef
                    name = $package.Name
                    version = "$($package.Value.resolved)"
                    purl = $bomRef
                    properties = @(
                        [ordered]@{ name = "$($script:SbomPropertyPrefix):kind"; value = 'nuget-lock' }
                        [ordered]@{ name = "$($script:SbomPropertyPrefix):path"; value = $File }
                    )
                    evidence = [ordered]@{ occurrences = @([ordered]@{ location = $File }) }
                }
            }
            if ($package.Value.type -eq 'Direct') {
                Add-SbomDependency -From 'root' -To $bomRef
            }
        }
    }
}

#_____________________________________________________________________________________________________
# Define log
$script:ScriptDirectory = Get-ScriptDirectory
Initialize-CILog -Prefix 'tec_pwsh_sbom'

#_____________________________________________________________________________________________________
$customexitcode = 0
try {
    $ErrorActionPreference = 'Stop'
    $commit = Initialize-CIRepository -RepositoryPath $RepositoryPath
    # The files of the tested commit; the CI tooling folder is never included.
    $files = @(((Invoke-RepositoryGit -Arguments @('ls-files', '-z')) -join "`n") -split "`0" |
        Where-Object { $_ -and -not $_.StartsWith('internal-ci/') -and (Test-Path -LiteralPath (Join-Path $script:RepositoryRoot $_) -PathType Leaf) })
    Write-CILog -info info -message "Files in the tested commit: $($files.Count)" -Verbose

    foreach ($file in $files) {
        $extension = [IO.Path]::GetExtension($file).ToLowerInvariant()
        if ($extension -eq '.psd1') {
            Add-SbomManifest -File $file
        } elseif (@('.ps1', '.psm1') -contains $extension) {
            Add-SbomScriptRequirement -File $file
        } elseif (@('.dll', '.exe') -contains $extension) {
            Add-SbomBinary -File $file
        } elseif ([IO.Path]::GetFileName($file) -eq 'packages.lock.json') {
            Add-SbomNuGetLock -File $file
        }
    }

    $repositoryName = if ($env:BUILD_REPOSITORY_NAME) { $env:BUILD_REPOSITORY_NAME } else { Split-Path -Leaf $script:RepositoryRoot }
    # An Azure Pipelines macro that is not defined stays as its own text: no ref is known then.
    $toolVersion = if ($TemplateRef -and -not $TemplateRef.StartsWith('$(')) { $TemplateRef } else { 'unknown' }
    # The commit of this template, when its folder is a checkout (a local copy may not be).
    $toolCommit = $null
    $savedPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $toolOutput = & git -C $script:ScriptDirectory rev-parse HEAD 2>&1
        if ($LASTEXITCODE -eq 0) {
            $toolCommit = "$toolOutput".Trim()
        }
    } catch {
        $toolCommit = $null
    } finally {
        $ErrorActionPreference = $savedPreference
    }
    $metadataComponent = [ordered]@{
        type = 'application'
        'bom-ref' = 'root'
        name = $repositoryName
        version = $commit
        properties = @(
            [ordered]@{ name = "$($script:SbomPropertyPrefix):commit"; value = $commit }
            [ordered]@{ name = "$($script:SbomPropertyPrefix):branch"; value = "$($env:BUILD_SOURCEBRANCH)" }
        )
    }
    $tool = [ordered]@{ type = 'application'; name = 'TemplatePipeline'; version = $toolVersion }
    if ($toolCommit) {
        $tool.properties = @([ordered]@{ name = "$($script:SbomPropertyPrefix):commit"; value = "$toolCommit" })
    }
    $dependencies = @(foreach ($key in $script:SbomDependencies.Keys) {
        [ordered]@{ ref = $key; dependsOn = @($script:SbomDependencies[$key]) }
    })
    $sbom = [ordered]@{
        bomFormat = 'CycloneDX'
        specVersion = '1.6'
        serialNumber = "urn:uuid:$([guid]::NewGuid())"
        version = 1
        metadata = [ordered]@{
            timestamp = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
            tools = [ordered]@{ components = @($tool) }
            component = $metadataComponent
        }
        components = @($script:SbomComponents.Values)
        dependencies = $dependencies
    }

    $sbomPath = Join-Path (Split-Path -Parent $script:fulllogpath) 'sbom.cdx.json'
    $json = ConvertTo-Json -InputObject $sbom -Depth 20
    [IO.File]::WriteAllText($sbomPath, $json, (New-Object System.Text.UTF8Encoding $false))
    Write-CILog -info info -message "SBOM written: $sbomPath ($($script:SbomComponents.Count) components)" -Verbose
} catch {
    $customexitcode = 1
    Write-CIFailure -Failure $_
}
exit $customexitcode
