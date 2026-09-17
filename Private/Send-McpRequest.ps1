function Select-McpProtocolVersion {
    [CmdletBinding()]
    param([string[]]$Supported)

    $Supported = @($Supported | Where-Object { $_ })
    if ($Supported -contains $script:ModernProtocolVersion) { return $script:ModernProtocolVersion }

    # Versions are ISO dates, so ordinal string comparison orders them correctly
    $newer = @($Supported | Where-Object { $_ -gt $script:ModernProtocolVersion } | Sort-Object)
    if ($newer.Count -gt 0) { return $newer[0] }

    $legacy = @($Supported | Where-Object { $_ -le $script:LegacyProtocolVersion })
    if ($legacy.Count -gt 0) { return $null }

    throw (New-McpError -ErrorId 'McpNoCompatibleVersion' -Category NotImplemented -TargetObject $Supported `
        -Message "Server supports protocol versions [$($Supported -join ', ')]; PSMcpClient supports $($script:ModernProtocolVersion) (modern) or $($script:LegacyProtocolVersion) and earlier (legacy).")
}

function Add-IgnoredMcpRequestId {
    param(
        [Parameter(Mandatory)]$Session,
        [Parameter(Mandatory)][string]$Id
    )

    $maxIgnoredIds = 256
    if ($Session.IgnoredIds.Count -ge $maxIgnoredIds) {
        $Session.IgnoredIds.RemoveAt(0)
    }
    $Session.IgnoredIds.Add($Id)
}

function Send-McpRequest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Session,
        [Parameter(Mandatory)][string]$Method,
        [System.Collections.IDictionary]$Params,
        [int]$TimeoutSec,
        [switch]$Raw,
        [switch]$NoVersionRetry
    )

    if ($TimeoutSec -le 0) { $TimeoutSec = $Session.RequestTimeoutSec }
    $name = $Session.Name

    $Session.NextId++
    $id = $Session.NextId

    # Copy so the caller's dictionary is never mutated (variable names are case-insensitive: not $params)
    $requestParams = [ordered]@{}
    if ($null -ne $Params) { foreach ($key in $Params.Keys) { $requestParams[$key] = $Params[$key] } }
    if ($Session.Era -eq 'Modern') {
        $requestParams['_meta'] = [ordered]@{
            'io.modelcontextprotocol/protocolVersion'    = $Session.NegotiatedVersion
            'io.modelcontextprotocol/clientInfo'         = $script:ClientInfo
            'io.modelcontextprotocol/clientCapabilities' = @{}
        }
    }

    $message = [ordered]@{ jsonrpc = '2.0'; id = $id; method = $Method; params = $requestParams }
    Write-McpMessage -Session $Session -Message $message

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $timeoutMs = [long]$TimeoutSec * 1000

    while ($true) {
        $remaining = $timeoutMs - $stopwatch.ElapsedMilliseconds
        $read = if ($remaining -le 0) { [pscustomobject]@{ State = 'Timeout'; Line = $null } } else { Read-McpLine -Session $Session -TimeoutMs ([int]$remaining) }

        if ($read.State -eq 'Timeout') {
            Add-IgnoredMcpRequestId -Session $Session -Id "$id"
            $elapsed = [int]$stopwatch.Elapsed.TotalSeconds
            throw (New-McpError -ErrorId 'McpRequestTimeout' -Category OperationTimeout -TargetObject $Method `
                -Exception ([System.TimeoutException]::new("MCP request '$Method' to server '$name' timed out after ${elapsed}s.")) `
                -Message "MCP request '$Method' to server '$name' timed out after ${elapsed}s.")
        }
        if ($read.State -eq 'Eof') {
            throw (New-McpProcessExitedError -Session $Session -Context "while waiting for a response to '$Method'")
        }

        $line = $read.Line
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        Write-Verbose "[$name] <- $line"

        try {
            $response = ConvertFrom-Json -InputObject $line -AsHashtable -Depth 64
        }
        catch {
            Write-Warning "[$name] non-JSON line on stdout ignored: $line"
            continue
        }
        if ($response -isnot [System.Collections.IDictionary]) {
            Write-Warning "[$name] unsupported JSON-RPC payload (batch or scalar) ignored"
            continue
        }

        $hasId = $response.ContainsKey('id') -and $null -ne $response['id']
        if (-not $hasId) {
            if ($response.ContainsKey('method')) {
                Receive-McpNotification -Session $Session -Message $response
            }
            else {
                Write-Verbose "[$name] malformed message without id or method ignored"
            }
            continue
        }

        if ($response.ContainsKey('method')) {
            # Legacy servers may send sampling/elicitation/roots requests; decline so they don't hang
            Write-Verbose "[$name] declining server-initiated request '$($response.method)' (id $($response.id))"
            Write-McpMessage -Session $Session -Message ([ordered]@{
                    jsonrpc = '2.0'
                    id      = $response.id
                    error   = @{ code = -32601; message = "Method not found: $($response.method) (PSMcpClient does not support server-initiated requests)" }
                })
            continue
        }

        $responseId = "$($response['id'])"
        if ($responseId -ne "$id") {
            if ($Session.IgnoredIds.Contains($responseId)) {
                $null = $Session.IgnoredIds.Remove($responseId)
                Write-Verbose "[$name] late response for timed-out request id $responseId discarded"
            }
            else {
                Write-Warning "[$name] response for unexpected request id $responseId (awaiting $id) discarded"
            }
            continue
        }

        if ($response.ContainsKey('error')) {
            $rpcError = $response['error']
            $supported = if ($rpcError.data -is [System.Collections.IDictionary]) { $rpcError.data['supported'] } else { $null }
            if ($rpcError.code -eq -32022 -and $Session.Era -eq 'Modern' -and -not $NoVersionRetry -and $supported) {
                $version = Select-McpProtocolVersion -Supported @($supported)
                if ($version) {
                    Write-Verbose "[$name] server rejected protocol version $($Session.NegotiatedVersion); retrying '$Method' with $version"
                    $Session.NegotiatedVersion = $version
                    return Send-McpRequest -Session $Session -Method $Method -Params $Params -TimeoutSec $TimeoutSec -Raw:$Raw -NoVersionRetry
                }
            }
            if ($Raw) { return $response }
            throw (New-McpError -ErrorId 'McpProtocolError' -Category InvalidOperation -TargetObject $rpcError `
                -Message "MCP error $($rpcError.code): $($rpcError.message)")
        }

        if ($Raw) { return $response }

        $result = $response['result']
        if ($result -is [System.Collections.IDictionary] -and $result.ContainsKey('resultType') -and $result['resultType'] -ne 'complete') {
            throw (New-McpError -ErrorId 'McpUnsupportedResult' -Category NotImplemented -TargetObject $result `
                -Message "Server returned resultType '$($result['resultType'])' for '$Method'; PSMcpClient supports only 'complete' results (no multi round-trip requests).")
        }
        return $result
    }
}
