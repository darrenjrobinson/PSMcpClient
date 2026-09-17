function ConvertTo-PSAISuiteTool {
    <#
    .SYNOPSIS
        Emits an MCP server's tools as PSAISuite tool definitions and registers global proxy functions for them.
    .DESCRIPTION
        Produces one hashtable per tool in the Name/Description/Parameters shape accepted by
        PSAISuite's Invoke-ChatCompletion -Tools. PSAISuite executes a tool by resolving its Name with Get-Command
        and splatting the model's arguments, so unless -NoProxyFunction is given a global function is created per
        tool whose parameters mirror the tool's inputSchema properties and which forwards to Invoke-McpTool.
        Proxy functions are removed by Disconnect-McpServer and re-created when the tool list is refreshed.
    .PARAMETER Server
        Session name.
    .PARAMETER Name
        Tool name(s) to include; wildcards supported. Default: all tools.
    .PARAMETER Prefix
        Prepends "<Prefix>_" to tool/function names to avoid collisions across servers.
    .PARAMETER NoProxyFunction
        Emit definitions only; do not create global functions.
    .EXAMPLE
        $tools = ConvertTo-PSAISuiteTool -Server everything
        Invoke-ChatCompletion -Messages 'Echo back the word hello' -Tools $tools -Model anthropic:claude-sonnet-5
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string]$Server,

        [string[]]$Name,

        [ValidatePattern('^[A-Za-z0-9_-]*$')]
        [string]$Prefix,

        [switch]$NoProxyFunction
    )

    $session = Get-McpSession -Server $Server
    if ($session.ToolsStale -or $null -eq $session.Tools) {
        Update-McpToolCache -Session $session
    }

    $tools = @(Select-McpTool -Session $session -Name $Name)

    if (-not $NoProxyFunction) {
        $session.ProxyRegistered = $true
        $session.ProxyPrefix = $Prefix
        $session.ProxyNames = $Name
        Register-McpProxyFunction -Session $session -Tools $tools -Prefix $Prefix
    }

    foreach ($tool in $tools) {
        @{
            Name        = Get-McpProxyFunctionName -Tool $tool -Prefix $Prefix
            Description = [string]$tool.Description
            Parameters  = $tool.InputSchema
        }
    }
}
