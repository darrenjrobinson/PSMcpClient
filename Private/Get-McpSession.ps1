function Get-McpSession {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Server
    )

    if (-not $script:Sessions.ContainsKey($Server)) {
        throw (New-McpError -ErrorId 'McpSessionNotFound' -Category ObjectNotFound -TargetObject $Server `
            -Message "No MCP session named '$Server'. Use Connect-McpServer first, or Get-McpServer to list active sessions.")
    }

    $script:Sessions[$Server]
}
