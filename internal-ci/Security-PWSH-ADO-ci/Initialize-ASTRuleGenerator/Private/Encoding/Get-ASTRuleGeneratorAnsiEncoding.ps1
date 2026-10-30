function Get-ASTRuleGeneratorAnsiEncoding {
    <#
    .SYNOPSIS
        Returns the encoding Windows PowerShell 5.1 uses for a script file without a byte order mark.
    .DESCRIPTION
        Windows PowerShell 5.1 reads such a file in the system's ANSI code page. On Windows, code
        page 0 is that code page, under both editions of PowerShell. Elsewhere Windows PowerShell
        does not exist, so the most common Windows code page, 1252 (Western European), is used.
    .EXAMPLE
        Get-ASTRuleGeneratorAnsiEncoding
    .INPUTS
        None
    .OUTPUTS
        System.Text.Encoding
    #>
    [CmdletBinding()]
    [OutputType([System.Text.Encoding])]
    param()

    # The variable is absent under Windows PowerShell 5.1, which only runs on Windows.
    $onWindows = (-not (Test-Path -Path 'Variable:IsWindows')) -or $IsWindows
    if ($onWindows) {
        [System.Text.Encoding]::GetEncoding(0)
    } else {
        [System.Text.Encoding]::GetEncoding(1252)
    }
}
