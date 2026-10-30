function Get-ASTRuleGeneratorFileHash {
    <#
    .SYNOPSIS
        Returns the SHA-256 hash of a file's bytes, in upper-case hexadecimal.
    .DESCRIPTION
        The value is the one Get-FileHash gives with its default algorithm, so a user can compute
        the hash to put in the allowlist with Get-FileHash. Reading the file is the only access
        the allow-list makes outside the module, kept in this function so tests can replace it.
    .PARAMETER Path
        The full path of the file.
    .EXAMPLE
        Get-ASTRuleGeneratorFileHash -Path 'C:\Scripts\Build.ps1'
    .INPUTS
        None
    .OUTPUTS
        System.String
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [string] $Path
    )

    (Get-FileHash -LiteralPath $Path -Algorithm SHA256 -ErrorAction Stop).Hash.ToUpperInvariant()
}
