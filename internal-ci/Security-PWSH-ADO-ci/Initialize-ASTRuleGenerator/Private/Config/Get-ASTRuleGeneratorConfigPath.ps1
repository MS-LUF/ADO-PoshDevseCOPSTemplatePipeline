function Get-ASTRuleGeneratorConfigPath {
    <#
    .SYNOPSIS
        Tells which rules file the module reads: the one in its own folder, or the one named by
        the ASTRULEGENERATOR_CONFIG environment variable.
    .DESCRIPTION
        When ASTRULEGENERATOR_CONFIG holds a path, that file is used instead of the one in the
        module folder. An unset, empty or blank variable counts as unset.

        The path must be absolute: on Windows a drive letter followed by a separator, or a UNC
        path; elsewhere a path that starts with a slash. PSScriptAnalyzer loads the module in
        runspaces whose current location is the process's working directory, not the folder the
        user sees in PowerShell, so a relative path would point to an unexpected file. A
        relative path is therefore an error.
    .PARAMETER ModuleRoot
        The folder of the module, where the default rules file is.
    .EXAMPLE
        Get-ASTRuleGeneratorConfigPath -ModuleRoot $PSScriptRoot
    .INPUTS
        None
    .OUTPUTS
        System.Management.Automation.PSCustomObject
    #>
    [CmdletBinding()]
    [OutputType([System.Management.Automation.PSCustomObject])]
    param(
        [Parameter(Mandatory = $true)]
        [string] $ModuleRoot
    )

    $override = [System.Environment]::GetEnvironmentVariable($script:ConfigEnvironmentVariable)
    if ([string]::IsNullOrWhiteSpace($override)) {
        return [PSCustomObject]@{
            Path            = Join-Path $ModuleRoot $script:ConfigFileName
            FromEnvironment = $false
        }
    }

    # $IsWindows does not exist under Windows PowerShell 5.1, which only runs on Windows.
    $onWindows = ($null -eq (Get-Variable -Name IsWindows -ValueOnly -ErrorAction SilentlyContinue)) -or $IsWindows
    if ($onWindows) {
        $absolute = $override -match '^([A-Za-z]:[\\/]|\\\\|//)'
    } else {
        $absolute = $override.StartsWith('/')
    }
    if (-not $absolute) {
        throw "Initialize-ASTRuleGenerator: $($script:ConfigEnvironmentVariable) must hold an absolute path, not '$override'."
    }

    [PSCustomObject]@{
        Path            = $override
        FromEnvironment = $true
    }
}
