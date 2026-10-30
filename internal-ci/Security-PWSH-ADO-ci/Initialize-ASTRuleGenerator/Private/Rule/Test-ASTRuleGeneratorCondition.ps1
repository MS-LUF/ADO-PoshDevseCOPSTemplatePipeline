function Test-ASTRuleGeneratorCondition {
    <#
    .SYNOPSIS
        Compares each of a list of values with a pattern, using one of the supported operators.
    .DESCRIPTION
        The operator is chosen from a fixed list by a switch statement, so no expression is
        built from the rule. Each result follows PowerShell's own rules for that operator,
        converted to a Boolean.

        With SkipNull, a null value never matches. Rules using SearchStringPattern compare text,
        and a value that could not be read has no text to compare.

        The result has one Boolean per value, in the same order. A comparison that fails with an
        error, for example because the value cannot be converted to the pattern's type, counts
        as not matching, and a non-terminating error names the rule the first time it happens while
        the module is loaded.
    .PARAMETER Value
        The values read from the AST nodes.
    .PARAMETER Operator
        The operator name without its leading hyphen, in lower case, for example like or cmatch.
    .PARAMETER Pattern
        The value from the rule to compare with.
    .PARAMETER SkipNull
        Makes a null value count as not matching without comparing it.
    .PARAMETER RuleName
        The name of the rule being evaluated, used in the error report.
    .EXAMPLE
        Test-ASTRuleGeneratorCondition -Value $values -Operator 'like' -Pattern '*Win32_Process*' -SkipNull -RuleName 'WMI classes'
    .INPUTS
        None
    .OUTPUTS
        System.Boolean[]
    #>
    [CmdletBinding()]
    [OutputType([bool[]], [System.Array])]
    param(
        # A node whose property is missing has a null value, which must reach the comparison.
        [Parameter(Mandatory = $true)]
        [AllowNull()]
        [AllowEmptyCollection()]
        [object[]] $Value,

        [Parameter(Mandatory = $true)]
        [string] $Operator,

        [Parameter(Mandatory = $true)]
        [AllowNull()]
        [AllowEmptyString()]
        [object] $Pattern,

        [switch] $SkipNull,

        [Parameter(Mandatory = $true)]
        [string] $RuleName
    )

    $matched = [bool[]]::new($Value.Count)
    for ($i = 0; $i -lt $Value.Count; $i++) {
        $item = $Value[$i]
        if ($SkipNull -and $null -eq $item) {
            continue
        }
        try {
            $result = switch -Exact ($Operator) {
                'eq' { $item -eq $Pattern }
                'ne' { $item -ne $Pattern }
                'like' { $item -like $Pattern }
                'notlike' { $item -notlike $Pattern }
                'match' { $item -match $Pattern }
                'notmatch' { $item -notmatch $Pattern }
                'gt' { $item -gt $Pattern }
                'ge' { $item -ge $Pattern }
                'lt' { $item -lt $Pattern }
                'le' { $item -le $Pattern }
                'contains' { $item -contains $Pattern }
                'notcontains' { $item -notcontains $Pattern }
                'in' { $item -in $Pattern }
                'notin' { $item -notin $Pattern }
                'ceq' { $item -ceq $Pattern }
                'cne' { $item -cne $Pattern }
                'clike' { $item -clike $Pattern }
                'cnotlike' { $item -cnotlike $Pattern }
                'cmatch' { $item -cmatch $Pattern }
                'cnotmatch' { $item -cnotmatch $Pattern }
                'cgt' { $item -cgt $Pattern }
                'cge' { $item -cge $Pattern }
                'clt' { $item -clt $Pattern }
                'cle' { $item -cle $Pattern }
                'ccontains' { $item -ccontains $Pattern }
                'cnotcontains' { $item -cnotcontains $Pattern }
                'cin' { $item -cin $Pattern }
                'cnotin' { $item -cnotin $Pattern }
                default { throw "Unsupported operator '$Operator'." }
            }
            $matched[$i] = [bool] $result
        } catch {
            Write-ASTRuleGeneratorEvaluationError -RuleName $RuleName -Message $_.Exception.Message
        }
    }
    , $matched
}
