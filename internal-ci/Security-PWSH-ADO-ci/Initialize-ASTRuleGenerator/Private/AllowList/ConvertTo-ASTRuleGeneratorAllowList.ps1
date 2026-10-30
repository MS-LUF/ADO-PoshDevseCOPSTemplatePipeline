function ConvertTo-ASTRuleGeneratorAllowList {
    <#
    .SYNOPSIS
        Checks the allowlist section of the rules file and returns it ready to use.
    .DESCRIPTION
        The allowlist section is optional. When present, it is an object that may hold two lists:
        FileNamePattern, wildcard patterns compared with the name of the analysed file (not its
        path), and Sha256, the SHA-256 hashes of files to skip, as Get-FileHash gives them.

        Any problem throws: a section that is not an object, a key other than these two, a
        pattern that is empty, holds a path separator or is not a valid wildcard pattern, or a
        hash that is not 64 hexadecimal characters. The module then fails to load, so that a
        mistake in the list never silently skips other files than intended.

        The returned object has the patterns, the hashes in upper case, and HasEntry, which is
        true when at least one entry is present.
    .PARAMETER AllowList
        The allowlist property of the rules file as read by ConvertFrom-Json, or null when the
        file has none.
    .EXAMPLE
        ConvertTo-ASTRuleGeneratorAllowList -AllowList $config.allowlist
    .INPUTS
        None
    .OUTPUTS
        System.Management.Automation.PSCustomObject
    #>
    [CmdletBinding()]
    [OutputType([System.Management.Automation.PSCustomObject])]
    param(
        [Parameter(Mandatory = $true)]
        [AllowNull()]
        [object] $AllowList
    )

    $pattern = @()
    $hash = @()
    if ($null -ne $AllowList) {
        if ($AllowList -isnot [System.Management.Automation.PSCustomObject]) {
            throw 'allowlist must be an object with FileNamePattern and Sha256 lists'
        }
        foreach ($name in @($AllowList.PSObject.Properties | ForEach-Object { $_.Name })) {
            if ($script:AllowListKey -notcontains $name) {
                throw "allowlist has an unknown key '$name' (supported: $($script:AllowListKey -join ', '))"
            }
        }

        foreach ($value in @($AllowList.FileNamePattern | Where-Object { $null -ne $_ })) {
            if (-not ($value -is [string]) -or [string]::IsNullOrWhiteSpace($value)) {
                throw "allowlist FileNamePattern '$value' must be a non-empty string"
            }
            if ($value.IndexOfAny([char[]]@('\', '/')) -ge 0) {
                throw "allowlist FileNamePattern '$value' must be a file name pattern, without a path"
            }
            try {
                [void] ('' -like $value)
            } catch {
                throw "allowlist FileNamePattern '$value' is not a valid wildcard pattern ($($_.Exception.Message))"
            }
            $pattern += $value
        }

        foreach ($value in @($AllowList.Sha256 | Where-Object { $null -ne $_ })) {
            if (-not ($value -is [string] -and $value -match '^[0-9A-Fa-f]{64}$')) {
                throw "allowlist Sha256 '$value' must be 64 hexadecimal characters"
            }
            $hash += $value.ToUpperInvariant()
        }
    }

    [PSCustomObject]@{
        FileNamePattern = [string[]] $pattern
        Sha256          = [string[]] $hash
        HasEntry        = ($pattern.Count + $hash.Count) -gt 0
    }
}
