function Test-ASTRuleGeneratorAllowList {
    <#
    .SYNOPSIS
        Tells whether a file is on the allow-list, and why.
    .DESCRIPTION
        The file name, without its path, is compared with each FileNamePattern using -like, so
        the comparison ignores case. When no pattern matches and the allow-list holds hashes, the
        SHA-256 of the file is computed and looked up.

        The result is a short reason, such as "file name pattern 'Build-*.ps1'" or "SHA-256
        3F2A...", or nothing when the file is not on the allow-list.

        When the hash cannot be computed, the file is treated as not on the allow-list, so it is
        scanned, and a non-terminating error reports the problem.
    .PARAMETER FilePath
        The full path of the analysed file.
    .PARAMETER AllowList
        The allow-list returned by ConvertTo-ASTRuleGeneratorAllowList.
    .EXAMPLE
        Test-ASTRuleGeneratorAllowList -FilePath 'C:\Scripts\Build.ps1' -AllowList $allowList
    .INPUTS
        None
    .OUTPUTS
        System.String
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [string] $FilePath,

        [Parameter(Mandatory = $true)]
        [System.Management.Automation.PSObject] $AllowList
    )

    $fileName = [System.IO.Path]::GetFileName($FilePath)
    foreach ($pattern in $AllowList.FileNamePattern) {
        if ($fileName -like $pattern) {
            return "file name pattern '$pattern'"
        }
    }

    if ($AllowList.Sha256.Count -gt 0) {
        try {
            $hash = Get-ASTRuleGeneratorFileHash -Path $FilePath
        } catch {
            $exception = [System.IO.IOException]::new("Initialize-ASTRuleGenerator: the SHA-256 of '$FilePath' could not be computed for the allow-list, so the file is scanned: $($_.Exception.Message)")
            $PSCmdlet.WriteError([System.Management.Automation.ErrorRecord]::new($exception, 'AllowListHashFailed', [System.Management.Automation.ErrorCategory]::ReadError, $FilePath))
            return
        }
        if ($AllowList.Sha256 -contains $hash) {
            return "SHA-256 $hash"
        }
    }
}
