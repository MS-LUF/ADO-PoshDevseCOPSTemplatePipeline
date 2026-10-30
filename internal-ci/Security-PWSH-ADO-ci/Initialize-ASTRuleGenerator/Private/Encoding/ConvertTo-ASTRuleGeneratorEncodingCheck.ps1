function ConvertTo-ASTRuleGeneratorEncodingCheck {
    <#
    .SYNOPSIS
        Checks the encodingcheck setting of the rules file and tells whether the check is on.
    .DESCRIPTION
        The encodingcheck setting is optional. Absent, the check is on. Enable turns it on and
        Disable turns it off, ignoring case, as for a rule's Status.

        Any other value throws. The module then fails to load, so that a mistake in the setting
        never silently turns the check off.
    .PARAMETER EncodingCheck
        The encodingcheck property of the rules file as read by ConvertFrom-Json, or null when the
        file has none.
    .EXAMPLE
        ConvertTo-ASTRuleGeneratorEncodingCheck -EncodingCheck $config.encodingcheck
    .INPUTS
        None
    .OUTPUTS
        System.Boolean
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)]
        [AllowNull()]
        [object] $EncodingCheck
    )

    if ($null -eq $EncodingCheck) {
        return $true
    }
    if ($EncodingCheck -is [string]) {
        if ($EncodingCheck -eq 'Enable') {
            return $true
        }
        if ($EncodingCheck -eq 'Disable') {
            return $false
        }
    }
    throw "encodingcheck '$EncodingCheck' must be Enable or Disable"
}
