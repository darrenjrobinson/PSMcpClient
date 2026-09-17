function Read-McpConfig {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ConfigPath,
        [string[]]$Name
    )

    if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
        throw (New-McpError -ErrorId 'McpConfigNotFound' -Category ObjectNotFound -TargetObject $ConfigPath `
            -Message "MCP config file not found: $ConfigPath")
    }

    $config = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json -AsHashtable -Depth 32
    $servers = if ($config -is [System.Collections.IDictionary]) { $config['mcpServers'] } else { $null }
    if ($servers -isnot [System.Collections.IDictionary]) {
        throw (New-McpError -ErrorId 'McpConfigInvalid' -Category InvalidData -TargetObject $ConfigPath `
            -Message "MCP config file '$ConfigPath' has no 'mcpServers' object.")
    }

    $selected = if ($Name) {
        foreach ($n in $Name) {
            if (-not $servers.ContainsKey($n)) {
                throw (New-McpError -ErrorId 'McpConfigServerNotFound' -Category ObjectNotFound -TargetObject $n `
                    -Message "Server '$n' not found in '$ConfigPath'. Available: $(@($servers.Keys) -join ', ')")
            }
            $n
        }
    }
    else {
        @($servers.Keys)
    }

    $knownKeys = @('command', 'args', 'env', 'cwd', 'type', 'disabled')
    foreach ($key in $selected) {
        $entry = $servers[$key]
        if ($entry -isnot [System.Collections.IDictionary]) {
            Write-Warning "Skipping '$key': entry is not an object."
            continue
        }

        $type = [string]$entry['type']
        if ($type -and $type -notin 'stdio') {
            Write-Warning "Skipping '$key': transport type '$type' is not supported (stdio only)."
            continue
        }
        if ($entry['disabled'] -eq $true) {
            Write-Verbose "Skipping '$key': marked disabled."
            continue
        }
        if (-not $entry['command']) {
            Write-Warning "Skipping '$key': no 'command' defined."
            continue
        }
        foreach ($k in $entry.Keys) {
            if ($k -notin $knownKeys) { Write-Verbose "Config '$key': ignoring unknown key '$k'" }
        }

        $arguments = if ($null -ne $entry['args']) { @($entry['args'] | ForEach-Object { [string]$_ }) } else { @() }

        @{
            Name             = [string]$key
            Command          = [string]$entry['command']
            Arguments        = $arguments
            Environment      = $entry['env']
            WorkingDirectory = [string]$entry['cwd']
        }
    }
}
