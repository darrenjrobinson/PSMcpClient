function Get-McpTool {
    <#
    .SYNOPSIS
        Returns the tools exposed by an MCP server (cached per session).
    .PARAMETER Server
        Session name.
    .PARAMETER Name
        Tool name(s); wildcards supported.
    .PARAMETER Force
        Re-fetch tools/list even if the cache is fresh.
    .EXAMPLE
        Get-McpTool -Server everything
    .EXAMPLE
        Get-McpTool -Server everything -Name 'get*'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string]$Server,

        [Parameter(Position = 1)]
        [string[]]$Name,

        [switch]$Force
    )

    $session = Get-McpSession -Server $Server
    if ($Force -or $session.ToolsStale -or $null -eq $session.Tools) {
        Update-McpToolCache -Session $session
    }

    $tools = @(Select-McpTool -Session $session -Name $Name)

    foreach ($pattern in $Name) {
        if (-not [System.Management.Automation.WildcardPattern]::ContainsWildcardCharacters($pattern) -and -not ($tools | Where-Object Name -eq $pattern)) {
            Write-Error -ErrorRecord (New-McpError -ErrorId 'McpToolNotFound' -Category ObjectNotFound -TargetObject $pattern `
                    -Message "Tool '$pattern' not found on server '$Server'.")
        }
    }

    $tools
}
