@{
    RootModule           = 'PSMcpClient.psm1'
    ModuleVersion        = '0.1.0'
    GUID                 = '0442d057-bf27-4029-ac03-b13f8d8f032e'
    Author               = 'Darren Robinson'
    Description          = 'MCP (Model Context Protocol) stdio client for PowerShell. Connect to published MCP servers, list and call their tools, and expose them to LLMs via PSAISuite Invoke-ChatCompletion -Tools.'
    PowerShellVersion    = '7.2'
    CompatiblePSEditions = @('Core')
    FunctionsToExport    = @(
        'Connect-McpServer'
        'Disconnect-McpServer'
        'Get-McpServer'
        'Get-McpTool'
        'Invoke-McpTool'
        'ConvertTo-PSAISuiteTool'
    )
    CmdletsToExport      = @()
    VariablesToExport    = @()
    AliasesToExport      = @()
    PrivateData          = @{
        PSData = @{
            Tags         = @('MCP', 'ModelContextProtocol', 'AI', 'LLM', 'PSAISuite', 'Client', 'JSON-RPC', 'Tools', 'Agent', 'PowerShell', 'pwsh')
            ProjectUri   = 'https://github.com/darrenjrobinson/PSMcpClient'
            ReleaseNotes ='Initial release: stdio transport, dual-era (2026-07-28 modern and 2025-11-25 legacy) protocol support, tools/list, tools/call, PSAISuite tool bridge.'
        }
    }
}
