function Get-McpServer {
    <#
    .SYNOPSIS
        Lists active MCP sessions.
    .PARAMETER Server
        Session name(s) to return; omit for all.
    .EXAMPLE
        Get-McpServer
    #>
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)]
        [string[]]$Server
    )

    $names = if ($Server) { $Server } else { @($script:Sessions.Keys | Sort-Object) }

    foreach ($name in $names) {
        if (-not $script:Sessions.ContainsKey($name)) {
            Write-Error -ErrorRecord (New-McpError -ErrorId 'McpSessionNotFound' -Category ObjectNotFound -TargetObject $name `
                    -Message "No MCP session named '$name'.")
            continue
        }

        $s = $script:Sessions[$name]
        $exited = try { $s.Process.HasExited } catch { $true }
        [pscustomobject]@{
            PSTypeName      = 'PSMcpClient.Server'
            Name            = $s.Name
            ServerName      = $s.ServerInfo.name
            ServerVersion   = $s.ServerInfo.version
            ProtocolVersion = $s.NegotiatedVersion
            Era             = $s.Era
            ProcessId       = $s.Process.Id
            Connected       = -not $exited
            ToolCount       = if ($null -ne $s.Tools) { @($s.Tools).Count } else { $null }
            ToolsStale      = $s.ToolsStale
            Command         = $s.Command
        }
    }
}
