function Select-McpTool {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Session,
        [string[]]$Name
    )

    $tools = @($Session.Tools)
    if (-not $Name) { return $tools }

    foreach ($tool in $tools) {
        foreach ($pattern in $Name) {
            if ($tool.Name -like $pattern) { $tool; break }
        }
    }
}

function Update-McpToolCache {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Session
    )

    $tools = [System.Collections.Generic.List[object]]::new()
    $cursor = $null
    do {
        $params = @{}
        if ($cursor) { $params['cursor'] = $cursor }
        $result = Send-McpRequest -Session $Session -Method 'tools/list' -Params $params

        foreach ($tool in @($result['tools'])) {
            if ($tool -isnot [System.Collections.IDictionary]) { continue }
            $schema = $tool['inputSchema']
            if ($schema -isnot [System.Collections.IDictionary]) { $schema = @{ type = 'object'; properties = @{} } }
            $tools.Add([pscustomobject]@{
                    PSTypeName  = 'PSMcpClient.Tool'
                    Name        = [string]$tool['name']
                    Description = [string]$tool['description']
                    InputSchema = $schema
                    Server      = $Session.Name
                })
        }
        $cursor = if ($result -is [System.Collections.IDictionary]) { $result['nextCursor'] } else { $null }
    } while ($cursor)

    $Session.Tools = $tools.ToArray()
    $Session.ToolsStale = $false
    Write-Verbose "[$($Session.Name)] cached $($tools.Count) tool(s)"

    if ($Session.ProxyRegistered) {
        $selected = @(Select-McpTool -Session $Session -Name $Session.ProxyNames)
        Register-McpProxyFunction -Session $Session -Tools $selected -Prefix $Session.ProxyPrefix
    }
}
