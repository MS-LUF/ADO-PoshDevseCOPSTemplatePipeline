function Get-ASTRuleGeneratorPropertyValue {
    <#
    .SYNOPSIS
        Reads a value from each of a list of AST nodes by following a property path.
    .DESCRIPTION
        Each step of the path is a member name read from the current value, or tostring(), which
        converts the current value to text. No code is built from the path. When a step meets a
        null value, the value for that node is null.

        With AsString, each value that is not null is converted to text at the end, the way
        rules using SearchStringPattern compare it.

        The result has one entry per node, in the same order. A node whose value cannot be read
        gets a null value, and a non-terminating error names the rule the first time it happens while
        the module is loaded.
    .PARAMETER InputObject
        The AST nodes to read from.
    .PARAMETER Path
        The steps of the property path, already checked by ConvertTo-ASTRuleGeneratorRule.
    .PARAMETER AsString
        Converts each value that is not null to text.
    .PARAMETER RuleName
        The name of the rule being evaluated, used in the error report.
    .EXAMPLE
        Get-ASTRuleGeneratorPropertyValue -InputObject $nodes -Path 'Right', 'tostring()', 'length' -RuleName 'Long strings'
    .INPUTS
        None
    .OUTPUTS
        System.Object[]
    #>
    [CmdletBinding()]
    [OutputType([System.Object[]], [System.Array])]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [object[]] $InputObject,

        [Parameter(Mandatory = $true)]
        [string[]] $Path,

        [switch] $AsString,

        [Parameter(Mandatory = $true)]
        [string] $RuleName
    )

    $values = [System.Collections.Generic.List[object]]::new($InputObject.Count)
    foreach ($node in $InputObject) {
        $value = $node
        try {
            foreach ($step in $Path) {
                if ($null -eq $value) {
                    break
                }
                if ($step -eq 'tostring()') {
                    $value = $value.ToString()
                } else {
                    $value = $value.$step
                }
            }
            if ($AsString -and $null -ne $value) {
                $value = $value.ToString()
            }
        } catch {
            Write-ASTRuleGeneratorEvaluationError -RuleName $RuleName -Message $_.Exception.Message
            $value = $null
        }
        $values.Add($value)
    }
    # The comma keeps the list whole instead of sending its items one by one.
    , $values.ToArray()
}
