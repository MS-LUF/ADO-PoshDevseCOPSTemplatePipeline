@{
    RootModule        = 'Initialize-ASTRuleGenerator.psm1'
    ModuleVersion     = '0.12.0'
    GUID              = '1b00b851-b466-4a87-a99f-071d0c00f84a'
    Author            = 'MS-LUF'
    CompanyName       = 'lucas-cueff.com'
    Copyright         = '(c) 2021 lucas-cueff.com Distributed under Artistic Licence 2.0 (https://opensource.org/licenses/artistic-license-2.0).'
    Description       = 'PSScriptAnalyzer custom rule module that turns simple rules declared in a JSON file into AST checks, for example to detect malicious PowerShell.'
    PowerShellVersion = '5.1'
    FunctionsToExport = @(
        'Measure-CustomASTRule'
    )
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
    FileList          = @(
        'Initialize-ASTRuleGenerator.psd1',
        'Initialize-ASTRuleGenerator.psm1',
        'Initialize-ASTRuleGenerator.json',
        'Private/AllowList/ConvertTo-ASTRuleGeneratorAllowList.ps1',
        'Private/AllowList/Get-ASTRuleGeneratorFileHash.ps1',
        'Private/AllowList/Test-ASTRuleGeneratorAllowList.ps1',
        'Private/Config/Get-ASTRuleGeneratorConfigPath.ps1',
        'Private/Config/Read-ASTRuleGeneratorConfig.ps1',
        'Private/Encoding/ConvertTo-ASTRuleGeneratorEncodingCheck.ps1',
        'Private/Encoding/Get-ASTRuleGeneratorAnsiEncoding.ps1',
        'Private/Encoding/Get-ASTRuleGeneratorFileByte.ps1',
        'Private/Encoding/Test-ASTRuleGeneratorEncoding.ps1',
        'Private/Rule/ConvertTo-ASTRuleGeneratorRule.ps1',
        'Private/Rule/Get-ASTRuleGeneratorPropertyValue.ps1',
        'Private/Rule/Test-ASTRuleGeneratorCondition.ps1',
        'Private/Rule/Write-ASTRuleGeneratorEvaluationError.ps1',
        'Public/Measure-CustomASTRule.ps1',
        'en-US/Initialize-ASTRuleGenerator-help.xml'
    )
    PrivateData       = @{
        PSData = @{
            Tags         = @('AST', 'AbstractSyntaxTree', 'PowerShell', 'ScriptAnalyzer', 'PSScriptAnalyzer', 'CustomSecurityAnalyzer')
            LicenseUri   = 'https://opensource.org/licenses/artistic-license-2.0'
            ProjectUri   = 'https://github.com/MS-LUF/Initialize-ASTRuleGenerator'
            IconUri      = 'http://www.lucas-cueff.com/files/gallery.png'
            ReleaseNotes = 'v0.12.0 - New Error finding for a file that Windows PowerShell 5.1 and PowerShell 7 read as different code (no byte order mark), with an encodingcheck setting to turn it off. See the change log in README.md.'
        }
    }
}
