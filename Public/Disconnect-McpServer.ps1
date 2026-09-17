function Disconnect-McpServer {
    <#
    .SYNOPSIS
        Terminates MCP server session(s), their process trees and any registered proxy functions.
    .PARAMETER Server
        Session name(s). Accepts pipeline input from Get-McpServer.
    .PARAMETER All
        Disconnect every active session.
    .EXAMPLE
        Disconnect-McpServer -Server everything
    .EXAMPLE
        Disconnect-McpServer -All
    #>
    [CmdletBinding(DefaultParameterSetName = 'Named')]
    param(
        [Parameter(Mandatory, ParameterSetName = 'Named', Position = 0, ValueFromPipeline, ValueFromPipelineByPropertyName)]
        [Alias('Name')]
        [string[]]$Server,

        [Parameter(Mandatory, ParameterSetName = 'All')]
        [switch]$All
    )

    process {
        $targets = if ($All) { @($script:Sessions.Keys) } else { $Server }

        foreach ($name in $targets) {
            if (-not $script:Sessions.ContainsKey($name)) {
                Write-Error -ErrorRecord (New-McpError -ErrorId 'McpSessionNotFound' -Category ObjectNotFound -TargetObject $name `
                        -Message "No MCP session named '$name'.")
                continue
            }
            Remove-McpSession -Session $script:Sessions[$name]
            Write-Verbose "Disconnected '$name'"
        }
    }
}
