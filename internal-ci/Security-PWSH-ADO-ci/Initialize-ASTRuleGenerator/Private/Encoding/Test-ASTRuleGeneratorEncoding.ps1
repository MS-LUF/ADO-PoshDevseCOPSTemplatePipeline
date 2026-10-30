function Test-ASTRuleGeneratorEncoding {
    <#
    .SYNOPSIS
        Tells whether Windows PowerShell 5.1 and PowerShell 7 would read a script file as different code.
    .DESCRIPTION
        A file without a byte order mark is read by Windows PowerShell 5.1 in the system's ANSI
        code page and by PowerShell 7 as UTF-8. When the file holds non-ASCII characters, the two
        readings can differ. In code page 1252, for example, the UTF-8 bytes of an arrow read as
        characters that include a curly quote, which PowerShell treats as a quote. Code can then
        be inside a string for one edition and run by the other.

        Both readings are tokenized, and the kinds of their tokens and their numbers of parse
        errors are compared. Text inside strings and comments may differ without counting.

        The result is the ANSI code page number when the readings differ, and nothing otherwise:
        for a file with a byte order mark, with only ASCII characters, or when the ANSI code page
        is UTF-8 itself.

        When the file cannot be read, the check is skipped and a non-terminating error reports the
        problem.
    .PARAMETER FilePath
        The full path of the analysed file.
    .EXAMPLE
        Test-ASTRuleGeneratorEncoding -FilePath 'C:\Scripts\Build.ps1'
    .INPUTS
        None
    .OUTPUTS
        System.Int32
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory = $true)]
        [string] $FilePath
    )

    try {
        $bytes = Get-ASTRuleGeneratorFileByte -Path $FilePath
    } catch {
        $exception = [System.IO.IOException]::new("Initialize-ASTRuleGenerator: '$FilePath' could not be read for the encoding check, so the check is skipped: $($_.Exception.Message)")
        $PSCmdlet.WriteError([System.Management.Automation.ErrorRecord]::new($exception, 'EncodingCheckReadFailed', [System.Management.Automation.ErrorCategory]::ReadError, $FilePath))
        return
    }

    if ($null -eq $bytes -or $bytes.Length -eq 0) {
        return
    }
    # Any byte order mark (UTF-8, UTF-16 or UTF-32) makes both editions read the same encoding.
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        return
    }
    if ($bytes.Length -ge 2 -and (($bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) -or ($bytes[0] -eq 0xFE -and $bytes[1] -eq 0xFF))) {
        return
    }
    if ($bytes.Length -ge 4 -and $bytes[0] -eq 0 -and $bytes[1] -eq 0 -and $bytes[2] -eq 0xFE -and $bytes[3] -eq 0xFF) {
        return
    }

    $ansi = Get-ASTRuleGeneratorAnsiEncoding
    if ($ansi.CodePage -eq 65001) {
        return
    }
    # Invalid UTF-8 bytes become replacement characters, as PowerShell 7 reads them. A regular
    # expression finds non-ASCII text far faster than a loop over the bytes.
    $utf8Text = [System.Text.UTF8Encoding]::new($false, $false).GetString($bytes)
    if ($utf8Text -notmatch '[^\x00-\x7F]') {
        return
    }

    $shape = foreach ($text in @($utf8Text, $ansi.GetString($bytes))) {
        $tokens = $null
        $parseErrors = $null
        [void] [System.Management.Automation.Language.Parser]::ParseInput($text, [ref] $tokens, [ref] $parseErrors)
        (@($tokens | ForEach-Object { $_.Kind }) -join ',') + "|$(@($parseErrors).Count)"
    }
    if ($shape[0] -ne $shape[1]) {
        $ansi.CodePage
    }
}
