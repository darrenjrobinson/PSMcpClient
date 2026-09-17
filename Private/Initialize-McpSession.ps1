function Initialize-McpSession {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Session
    )

    $name = $Session.Name

    # Probe as a modern client so _meta is attached; the reply (or its absence) reveals the server's era
    $Session.Era = 'Modern'
    $Session.NegotiatedVersion = $script:ModernProtocolVersion

    $probe = $null
    try {
        $probe = Send-McpRequest -Session $Session -Method 'server/discover' -Params @{} -TimeoutSec $Session.DiscoverTimeoutSec -Raw
    }
    catch {
        if ($_.FullyQualifiedErrorId -like 'McpRequestTimeout*') {
            Write-Verbose "[$name] server/discover probe timed out; treating server as legacy"
        }
        else {
            throw
        }
    }

    if ($probe -and $probe.ContainsKey('result') -and $probe['result'] -is [System.Collections.IDictionary]) {
        $result = $probe['result']
        $supported = if ($result['supportedVersions']) { @($result['supportedVersions']) } else { @($script:ModernProtocolVersion) }
        $version = Select-McpProtocolVersion -Supported $supported
        if ($version) {
            $Session.Era = 'Modern'
            $Session.NegotiatedVersion = $version
            $Session.Capabilities = $result['capabilities']
            $Session.Instructions = $result['instructions']
            $meta = $result['_meta']
            if ($meta -is [System.Collections.IDictionary]) {
                $Session.ServerInfo = $meta['io.modelcontextprotocol/serverInfo']
            }
            Write-Verbose "[$name] modern server, protocol version $version"
            return
        }
        Write-Verbose "[$name] server answered server/discover but only supports legacy versions; using initialize handshake"
    }
    elseif ($probe -and $probe.ContainsKey('error')) {
        $code = $probe['error'].code
        if ($code -eq -32022) {
            Write-Verbose "[$name] modern server with no mutually supported modern version; using initialize handshake"
        }
        else {
            Write-Verbose "[$name] server/discover rejected with error $code; treating server as legacy"
        }
    }

    $Session.Era = 'Legacy'
    $Session.NegotiatedVersion = $script:LegacyProtocolVersion
    $initParams = [ordered]@{
        protocolVersion = $script:LegacyProtocolVersion
        capabilities    = @{}
        clientInfo      = $script:ClientInfo
    }
    $result = Send-McpRequest -Session $Session -Method 'initialize' -Params $initParams -TimeoutSec $Session.InitializeTimeoutSec

    if ($result -is [System.Collections.IDictionary]) {
        if ($result['protocolVersion']) { $Session.NegotiatedVersion = [string]$result['protocolVersion'] }
        $Session.ServerInfo = $result['serverInfo']
        $Session.Capabilities = $result['capabilities']
        $Session.Instructions = $result['instructions']
    }

    Send-McpNotification -Session $Session -Method 'notifications/initialized'
    Write-Verbose "[$name] legacy server '$($Session.ServerInfo.name)', protocol version $($Session.NegotiatedVersion)"
}
