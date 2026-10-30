#Requires -Version 5.1

$script:ModuleRoot = $PSScriptRoot

# Name of the default rules file, kept in the module's own folder.
$script:ConfigFileName = 'Initialize-ASTRuleGenerator.json'
# Environment variable that can name another rules file, by absolute path. PSScriptAnalyzer
# passes a custom rule nothing but the AST, so the environment is the only way to choose it.
$script:ConfigEnvironmentVariable = 'ASTRULEGENERATOR_CONFIG'
# Comparison operators a rule may use, without the leading hyphen. Test-ASTRuleGeneratorCondition
# applies each one through a switch; a rule naming any other operator is skipped.
$script:SupportedOperator = @(
    'eq', 'ne', 'like', 'notlike', 'match', 'notmatch', 'gt', 'ge', 'lt', 'le',
    'contains', 'notcontains', 'in', 'notin',
    'ceq', 'cne', 'clike', 'cnotlike', 'cmatch', 'cnotmatch', 'cgt', 'cge', 'clt', 'cle',
    'ccontains', 'cnotcontains', 'cin', 'cnotin'
)
# Keys the optional allowlist section of the rules file may hold.
$script:AllowListKey = @('FileNamePattern', 'Sha256')
# Severity values a rule may use; info is the form the sample rules use for Information.
$script:SupportedSeverity = @('info', 'information', 'warning', 'error')
# Rules from the configuration once checked, built by Measure-CustomASTRule on its first call.
$script:CompiledRule = $null
# Names of the rules already reported as failing to evaluate, so each is reported once.
$script:RuleEvaluationReported = @{}

foreach ($helper in Get-ChildItem -Path (Join-Path $script:ModuleRoot 'Private') -Filter '*.ps1' -Recurse -File -ErrorAction SilentlyContinue) {
    . $helper.FullName
}

# The rules file is read each time the module is imported. PSScriptAnalyzer imports the module
# again for every file it analyses, so an edited file is used by its next run. A missing or
# unreadable file stops the import instead of leaving the module with other rules.
$configSource = Get-ASTRuleGeneratorConfigPath -ModuleRoot $script:ModuleRoot
$script:moduleconfig = Read-ASTRuleGeneratorConfig -Path $configSource.Path -FromEnvironment:$configSource.FromEnvironment
# An invalid allow-list stops the import as well: a mistake in it must not skip other files than
# intended.
try {
    $script:AllowList = ConvertTo-ASTRuleGeneratorAllowList -AllowList $script:moduleconfig.allowlist
} catch {
    throw "Initialize-ASTRuleGenerator: rules file '$($configSource.Path)' has an invalid allowlist: $($_.Exception.Message)"
}
# An invalid encodingcheck value stops the import too, rather than leaving the check off.
try {
    $script:EncodingCheck = ConvertTo-ASTRuleGeneratorEncodingCheck -EncodingCheck $script:moduleconfig.encodingcheck
} catch {
    throw "Initialize-ASTRuleGenerator: rules file '$($configSource.Path)' has an invalid encodingcheck: $($_.Exception.Message)"
}

foreach ($ruleFunction in Get-ChildItem -Path (Join-Path $script:ModuleRoot 'Public') -Filter '*.ps1' -File -ErrorAction SilentlyContinue) {
    . $ruleFunction.FullName
}

# PSScriptAnalyzer treats every exported function as a rule: only rule functions are listed here.
Export-ModuleMember -Function @(
    'Measure-CustomASTRule'
)
