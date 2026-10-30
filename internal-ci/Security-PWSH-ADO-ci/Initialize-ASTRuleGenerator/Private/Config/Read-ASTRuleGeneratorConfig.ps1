function Read-ASTRuleGeneratorConfig {
    <#
    .SYNOPSIS
        Reads the rules file and returns its content.
    .DESCRIPTION
        The file must exist, be valid JSON and hold a rules array. Otherwise the function throws,
        so the module fails to load rather than run with no rules or with other rules than the
        ones intended. The rules themselves are checked later, one by one, when they are used.
    .PARAMETER Path
        The path of the rules file.
    .PARAMETER FromEnvironment
        Says that the path came from the ASTRULEGENERATOR_CONFIG environment variable, so that an
        error names it.
    .EXAMPLE
        Read-ASTRuleGeneratorConfig -Path 'C:\Rules\Initialize-ASTRuleGenerator.json'
    .INPUTS
        None
    .OUTPUTS
        System.Management.Automation.PSCustomObject
    #>
    [CmdletBinding()]
    [OutputType([System.Management.Automation.PSCustomObject])]
    param(
        [Parameter(Mandatory = $true)]
        [string] $Path,

        [switch] $FromEnvironment
    )

    if ($FromEnvironment) {
        $source = "configuration file '$Path' set by $($script:ConfigEnvironmentVariable)"
    } else {
        $source = "configuration file $($script:ConfigFileName)"
    }

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        if ($FromEnvironment) {
            throw "Initialize-ASTRuleGenerator: $source not found"
        }
        # Same message as earlier versions, which scripts and tests may rely on.
        throw "$source missing in module folder"
    }

    try {
        $config = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    } catch {
        throw "Initialize-ASTRuleGenerator: $source could not be read as JSON: $($_.Exception.Message)"
    }

    if ($null -eq $config -or -not ($config.PSObject.Properties.Name -contains 'rules')) {
        throw "Initialize-ASTRuleGenerator: $source has no rules array"
    }
    $config
}
