function ConvertTo-ASTRuleGeneratorRule {
    <#
    .SYNOPSIS
        Checks one rule read from the JSON configuration and returns it ready to evaluate.
    .DESCRIPTION
        Every value of the rule is treated as data. The AST type must name a class of the
        System.Management.Automation.Language namespace that derives from Ast. The property path
        is a list of plain member names separated by dots, where the step tostring() is also
        accepted. The operator must be one of the comparison operators the module supports.
        Regular expressions and wildcard patterns are checked once here, so that a bad pattern
        does not fail on every node later. The optional MinimumCount must be a whole number of
        at least 1; without it, the rule reports from its first match.

        A rule that fails a check is not returned. A non-terminating error names the rule and
        the reason, and the other rules are not affected. It is an error rather than a warning
        because PSScriptAnalyzer passes the errors of a custom rule on to its caller but drops
        its warnings.
    .PARAMETER Rule
        One entry of the rules array of the JSON configuration, as returned by ConvertFrom-Json.
    .PARAMETER Index
        The position of the rule in the rules array, used to name a rule that has no Name.
    .EXAMPLE
        ConvertTo-ASTRuleGeneratorRule -Rule $config.rules[0] -Index 0
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
        [object] $Rule,

        [Parameter(Mandatory = $true)]
        [int] $Index
    )

    $label = "#$Index"
    if ($null -ne $Rule -and $Rule.Name -is [string] -and $Rule.Name.Trim()) {
        $label = "'$($Rule.Name)'"
    }

    $reason = $null
    $astType = $null
    $path = $null
    $operator = $null
    $mode = $null
    $pattern = @()

    if ($null -eq $Rule) {
        $reason = 'the rule is empty'
    } elseif (-not ($Rule.Name -is [string] -and $Rule.Name.Trim())) {
        $reason = 'Name is missing'
    } elseif (-not ($Rule.ASTType -is [string] -and $Rule.ASTType -match '^[A-Za-z][A-Za-z0-9]*$')) {
        $reason = 'ASTType must be the name of an AST class, letters and digits only'
    } else {
        $astType = [System.Management.Automation.Language.Ast].Assembly.GetType("System.Management.Automation.Language.$($Rule.ASTType)", $false, $true)
        if ($null -eq $astType -or -not [System.Management.Automation.Language.Ast].IsAssignableFrom($astType)) {
            $reason = "ASTType '$($Rule.ASTType)' is not an AST class of System.Management.Automation.Language"
        }
    }

    if (-not $reason) {
        if ($Rule.ASTProperty -is [string] -and $Rule.ASTProperty) {
            $path = [string[]]($Rule.ASTProperty -split '\.')
            foreach ($step in $path) {
                if (-not ($step -match '^[A-Za-z_][A-Za-z0-9_]*$' -or $step -eq 'tostring()')) {
                    $reason = "ASTProperty step '$step' is not a member name or tostring()"
                    break
                }
            }
        } else {
            $reason = 'ASTProperty is missing'
        }
    }

    if (-not $reason) {
        if ($Rule.Operator -is [string] -and $script:SupportedOperator -contains $Rule.Operator) {
            $operator = $Rule.Operator.ToLowerInvariant()
        } else {
            $reason = "Operator '$($Rule.Operator)' is not supported (supported: $($script:SupportedOperator -join ', '))"
        }
    }

    # Same precedence as before: SearchStringPattern wins when both are set.
    if (-not $reason) {
        if ($Rule.SearchStringPattern) {
            $mode = 'String'
            $pattern = @(foreach ($value in @($Rule.SearchStringPattern)) { [string] $value })
        } elseif ($Rule.SearchOtherPattern) {
            $mode = 'Other'
            $pattern = @($Rule.SearchOtherPattern)
            foreach ($value in $pattern) {
                if ($value -is [System.Management.Automation.PSCustomObject]) {
                    $reason = 'SearchOtherPattern values must be numbers, strings or booleans, not objects'
                    break
                }
            }
        } else {
            $reason = 'SearchStringPattern or SearchOtherPattern is required'
        }
    }

    if (-not $reason) {
        foreach ($value in $pattern) {
            try {
                if ($operator -match 'match$') {
                    [void] [regex]::new([string] $value)
                } elseif ($operator -match 'like$') {
                    [void] ('' -like [string] $value)
                }
            } catch {
                $reason = "pattern '$value' is not valid for -$operator ($($_.Exception.Message))"
                break
            }
        }
    }

    if (-not $reason -and -not ($Rule.Message -is [string])) {
        $reason = 'Message is missing'
    }
    if (-not $reason -and -not ($Rule.Severity -is [string] -and $script:SupportedSeverity -contains $Rule.Severity)) {
        $reason = "Severity '$($Rule.Severity)' is not supported (supported: $($script:SupportedSeverity -join ', '))"
    }

    # MinimumCount is optional; without it a single match is reported, as before it existed.
    $minimumCount = 1
    if (-not $reason -and $Rule.PSObject.Properties.Name -contains 'MinimumCount') {
        $value = $Rule.MinimumCount
        if (($value -is [int] -or $value -is [long]) -and $value -ge 1) {
            $minimumCount = [long] $value
        } else {
            $reason = "MinimumCount '$value' must be a whole number of at least 1"
        }
    }

    if ($reason) {
        $exception = [System.IO.InvalidDataException]::new("Initialize-ASTRuleGenerator: rule $label skipped: $reason.")
        $PSCmdlet.WriteError([System.Management.Automation.ErrorRecord]::new($exception, 'InvalidRule', [System.Management.Automation.ErrorCategory]::InvalidData, $Rule))
        return
    }

    [PSCustomObject]@{
        Name         = $Rule.Name
        AstType      = $astType
        PropertyPath = $path
        Operator     = $operator
        Mode         = $mode
        Pattern      = $pattern
        Message      = $Rule.Message
        Severity     = $Rule.Severity
        MinimumCount = $minimumCount
    }
}
