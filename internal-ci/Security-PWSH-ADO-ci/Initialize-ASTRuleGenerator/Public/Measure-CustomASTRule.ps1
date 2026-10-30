function Measure-CustomASTRule {
    <#
    .SYNOPSIS
        Applies the rules declared in a JSON rules file to a script, as a PSScriptAnalyzer custom rule.
    .DESCRIPTION
        Runs the simple rules declared in a JSON rules file on each script PSScriptAnalyzer analyses with this module as a custom rule path. It returns one finding for each part of the script that a rule matches. A finding is named after the rule, and its message is the rule's message followed by the pattern that matched.

        The rules file is Initialize-ASTRuleGenerator.json in the module folder. To use another file, set the environment variable ASTRULEGENERATOR_CONFIG to its absolute path. A rules file that is missing, is not JSON or has no rules array stops the module from loading: PSScriptAnalyzer then reports that it cannot find the rules, and Import-Module on the module manifest shows the reason. The file is read again by every analysis, so an edit is used by the next run.

        Each rule has a Status (Enable or Disable), a Name, an ASTType, an ASTProperty, an Operator, a Message, a Severity (info, warning or error), and either SearchStringPattern or SearchOtherPattern. Only rules whose Status is Enable run. A rule may also have a MinimumCount: it then reports its findings only when the script holds at least that many of them, which makes a weak signal useful when it is repeated.

        ASTType is the name of a class of the System.Management.Automation.Language namespace, for example StringConstantExpressionAst or CommandAst. ASTProperty is a property of that class, or a path of properties separated by dots, for example Right.Extent.Text. The step tostring() converts the value to text, as in Right.tostring().length. No other method call is allowed.

        Operator is a PowerShell comparison operator without its hyphen: eq, ne, like, notlike, match, notmatch, gt, ge, lt, le, contains, notcontains, in or notin, or its case-sensitive form starting with c, for example cmatch.

        SearchStringPattern lists values compared with the text of the property, such as wildcard patterns for like or regular expressions for match. SearchOtherPattern lists values compared with the property as it is, such as numbers. When a rule has both, SearchStringPattern is used.

        The rules file may also hold an allowlist section with two lists: FileNamePattern, wildcard patterns compared with the file name only (not its folders), ignoring case, and Sha256, the hashes of files as Get-FileHash gives them. A file on the list is not scanned; it gets one Warning finding that says why. A script given as a string has no file and is always scanned. An invalid allowlist stops the module from loading. Warning: a file name pattern lets any file with a matching name escape scanning, wherever it is. Prefer hashes, and keep the rules file out of the repository it scans unless that file is protected.

        Windows PowerShell 5.1 reads a script file without a byte order mark in the system's ANSI code page, while PowerShell 7 reads it as UTF-8. With some non-ASCII characters, such as an arrow or a dash, the two editions then see different code, and code can be hidden inside a string for one of them. Such a file gets one Error finding named Ambiguous file encoding; saving it as UTF-8 with a byte order mark removes the ambiguity. Outside Windows, code page 1252 is assumed. Set encodingcheck to Disable in the rules file to turn this check off; any value other than Enable or Disable stops the module from loading.

        Every value of a rule is used as data, never run as code. A rule that breaks these requirements is skipped and reported as a non-terminating error, once for each file analysed, and the other rules still run.
    .PARAMETER ScriptBlockAst
        The syntax tree of the script being analysed. PSScriptAnalyzer passes it when it runs the rule.
    .EXAMPLE
        Invoke-ScriptAnalyzer -Path .\MyScript.ps1 -CustomRulePath .\Initialize-ASTRuleGenerator.psd1

        Runs the enabled rules of the rules file in the module folder on MyScript.ps1, together with the rules of PSScriptAnalyzer itself.
    .EXAMPLE
        $env:ASTRULEGENERATOR_CONFIG = 'C:\Rules\my-rules.json'; Invoke-ScriptAnalyzer -Path .\MyScript.ps1 -CustomRulePath .\Initialize-ASTRuleGenerator.psd1

        Runs the enabled rules of C:\Rules\my-rules.json instead of the rules file in the module folder.
    .INPUTS
        None
    .OUTPUTS
        Microsoft.Windows.PowerShell.ScriptAnalyzer.Generic.DiagnosticRecord[]
    .NOTES
        The rules file shipped with the module holds enabled rules that detect common PowerShell threats and obfuscation, each naming its MITRE ATT&CK technique. Rules with the Error severity are the ones that showed no false positive on a corpus of legitimate modules. Disable or change rules in that file, or write your own file.
    #>
    [CmdletBinding()]
    [OutputType([Microsoft.Windows.Powershell.ScriptAnalyzer.Generic.DiagnosticRecord[]])]
    Param
    (
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [System.Management.Automation.Language.ScriptBlockAst]
        $ScriptBlockAst
    )
    Process
    {
        # PSScriptAnalyzer calls the rule once per script block of a file, functions included. The
        # outermost block already covers the nested ones, so scanning them too repeats findings.
        if ($null -ne $ScriptBlockAst.Parent) {
            return
        }

        # A file on the allow-list is not scanned. It leaves one Warning finding instead, so that
        # skipping is visible in reports and CI logs. A script given as a string has no file and
        # is always scanned.
        $file = $ScriptBlockAst.Extent.File
        if ($file -and $script:AllowList.HasEntry) {
            $reason = Test-ASTRuleGeneratorAllowList -FilePath $file -AllowList $script:AllowList
            if ($reason) {
                return [Microsoft.Windows.PowerShell.ScriptAnalyzer.Generic.DiagnosticRecord[]]@{
                    "Message"  = "File skipped by the allow-list ($reason)"
                    "Extent"   = $ScriptBlockAst.Extent
                    "RuleName" = 'Allow-list'
                    "Severity" = 'Warning'
                }
            }
        }

        # Rules are checked the first time they are needed while the module is loaded: a rule
        # that fails a check is reported once and left out, and the other rules still run.
        # PSScriptAnalyzer does not keep the module's state between files, so under it this
        # happens once per analysed file.
        if ($null -eq $script:CompiledRule) {
            $index = 0
            $script:CompiledRule = @(foreach ($rule in @($script:moduleconfig.rules)) {
                    if ($null -ne $rule -and $rule.Status -eq 'Enable') {
                        ConvertTo-ASTRuleGeneratorRule -Rule $rule -Index $index
                    }
                    $index++
                })
        }

        $results = @()
        # A file that Windows PowerShell 5.1 and PowerShell 7 read as different code can hide code
        # from a scan under either edition, so it is an Error. The rules still run on the reading
        # PSScriptAnalyzer parsed.
        if ($file -and $script:EncodingCheck) {
            $codePage = Test-ASTRuleGeneratorEncoding -FilePath $file
            if ($codePage) {
                $results += [Microsoft.Windows.PowerShell.ScriptAnalyzer.Generic.DiagnosticRecord[]]@{
                    "Message"  = "File read as different code by Windows PowerShell 5.1 (code page $codePage) and PowerShell 7 (UTF-8): save it as UTF-8 with a byte order mark (ATT&CK T1027)"
                    "Extent"   = $ScriptBlockAst.Extent
                    "RuleName" = 'Ambiguous file encoding'
                    "Severity" = 'Error'
                }
            }
        }

        foreach ($compiledRule in $script:CompiledRule) {
            # Nodes of the rule's type are found and read once, then compared with each pattern.
            # The predicate reads $astType from this scope; nothing from the configuration is
            # turned into code.
            $astType = $compiledRule.AstType
            $nodes = @($ScriptBlockAst.FindAll({ param($node) $node -is $astType }, $true))
            if ($nodes.Count -eq 0) {
                continue
            }
            $asString = $compiledRule.Mode -eq 'String'
            $values = Get-ASTRuleGeneratorPropertyValue -InputObject $nodes -Path $compiledRule.PropertyPath -AsString:$asString -RuleName $compiledRule.Name
            # A rule's findings are gathered over all its patterns first: with MinimumCount, the
            # rule reports only when the script holds at least that many of them.
            $ruleResults = @()
            foreach ($pattern in $compiledRule.Pattern) {
                $matched = Test-ASTRuleGeneratorCondition -Value $values -Operator $compiledRule.Operator -Pattern $pattern -SkipNull:$asString -RuleName $compiledRule.Name
                for ($i = 0; $i -lt $nodes.Count; $i++) {
                    if ($matched[$i]) {
                        $ruleResults += [Microsoft.Windows.PowerShell.ScriptAnalyzer.Generic.DiagnosticRecord[]]@{
                            "Message"  = "$($compiledRule.Message) : $($pattern)"
                            "Extent"   = $nodes[$i].Extent
                            "RuleName" = $compiledRule.Name
                            "Severity" = $compiledRule.Severity
                        }
                    }
                }
            }
            if ($ruleResults.Count -ge $compiledRule.MinimumCount) {
                $results += $ruleResults
            }
        }
        if ($results) {
            return $results
        }
    }
}
