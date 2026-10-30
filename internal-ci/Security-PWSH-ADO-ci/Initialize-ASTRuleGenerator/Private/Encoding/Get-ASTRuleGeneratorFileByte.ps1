function Get-ASTRuleGeneratorFileByte {
    <#
    .SYNOPSIS
        Returns the bytes of a file.
    .DESCRIPTION
        The encoding check needs the bytes as stored, before any decoding, to read them the way
        each edition of PowerShell does. Reading the file is kept in this function so tests can
        replace it.
    .PARAMETER Path
        The full path of the file.
    .EXAMPLE
        Get-ASTRuleGeneratorFileByte -Path 'C:\Scripts\Build.ps1'
    .INPUTS
        None
    .OUTPUTS
        System.Byte[]
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseOutputTypeCorrectly', '', Justification = 'The unary comma returns the byte array whole; the analyzer reads it as System.Array.')]
    [CmdletBinding()]
    [OutputType([byte[]])]
    param(
        [Parameter(Mandatory = $true)]
        [string] $Path
    )

    # The leading comma emits the array whole: unrolled, the caller would get an object array.
    # Write-Output -NoEnumerate still unrolls it under Windows PowerShell 5.1.
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    , $bytes
}
