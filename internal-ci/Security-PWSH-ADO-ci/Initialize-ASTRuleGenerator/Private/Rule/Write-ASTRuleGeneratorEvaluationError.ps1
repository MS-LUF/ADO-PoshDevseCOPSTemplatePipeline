function Write-ASTRuleGeneratorEvaluationError {
    <#
    .SYNOPSIS
        Reports, once per rule while the module is loaded, that a rule could not be evaluated.
    .DESCRIPTION
        The nodes concerned are reported as not matching, and the other rules still run. The
        report is a non-terminating error because PSScriptAnalyzer passes the errors of a custom
        rule on to its caller but drops its warnings. Only the first failure of each rule is
        reported, so a rule that fails on many nodes does not flood the output.

        PSScriptAnalyzer does not keep the module's state from one analysed file to the next, so
        when it runs the rule the failure is reported once for each file where it happens.
    .PARAMETER RuleName
        The name of the rule.
    .PARAMETER Message
        The reason for the first failure.
    .EXAMPLE
        Write-ASTRuleGeneratorEvaluationError -RuleName 'Long strings' -Message 'Cannot compare.'
    .INPUTS
        None
    .OUTPUTS
        None
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $RuleName,

        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string] $Message
    )

    if (-not $script:RuleEvaluationReported.ContainsKey($RuleName)) {
        $script:RuleEvaluationReported[$RuleName] = $true
        $exception = [System.InvalidOperationException]::new("Initialize-ASTRuleGenerator: rule '$RuleName' could not be evaluated on some nodes, which are reported as not matching: $Message")
        $PSCmdlet.WriteError([System.Management.Automation.ErrorRecord]::new($exception, 'RuleEvaluationFailed', [System.Management.Automation.ErrorCategory]::InvalidOperation, $RuleName))
    }
}
