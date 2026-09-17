# Minimal stdio MCP server used by the offline test suite.
# Modes: Legacy (initialize handshake), Modern (2026-07-28 per-request _meta), Silent (never answers server/discover).
param(
    [ValidateSet('Legacy', 'Modern', 'Silent')]
    [string]$Mode = 'Legacy'
)

$utf8 = [System.Text.UTF8Encoding]::new($false)
$reader = [System.IO.StreamReader]::new([System.Console]::OpenStandardInput(), $utf8)
$writer = [System.IO.StreamWriter]::new([System.Console]::OpenStandardOutput(), $utf8)
$writer.AutoFlush = $true
$stderr = [System.Console]::Error
$stderr.WriteLine("stub-server: starting in $Mode mode (pid $PID)")

$modernVersion = '2026-07-28'

$tools = @(
    @{ name = 'echo'; description = 'Echoes its arguments back as JSON text'
       inputSchema = @{ type = 'object'; properties = @{ message = @{ type = 'string' }; count = @{ type = 'integer' }; flag = @{ type = 'boolean' }; 'kebab-name' = @{ type = 'string' }; ratio = @{ type = 'number' }; tags = @{ type = 'array'; items = @{ type = 'string' } }; nested = @{ type = 'object' } } } }
    @{ name = 'fail'; description = 'Always reports a tool error'
       inputSchema = @{ type = 'object'; properties = @{ reason = @{ type = 'string' } } } }
    @{ name = 'plain'; description = 'Returns plain text'
       inputSchema = @{ type = 'object'; properties = @{} } }
    @{ name = 'multi'; description = 'Returns two text blocks and an image block'
       inputSchema = @{ type = 'object'; properties = @{} } }
    @{ name = 'structured'; description = 'Returns structuredContent alongside text'
       inputSchema = @{ type = 'object'; properties = @{} } }
    @{ name = 'sleep'; description = 'Sleeps for the given number of seconds'
       inputSchema = @{ type = 'object'; properties = @{ seconds = @{ type = 'number' } }; required = @('seconds') } }
    @{ name = 'notify_changed'; description = 'Emits notifications/tools/list_changed before replying'
       inputSchema = @{ type = 'object'; properties = @{} } }
    @{ name = 'crash'; description = 'Terminates the server process'
       inputSchema = @{ type = 'object'; properties = @{} } }
    @{ name = 'request_sampling'; description = 'Sends a server-initiated sampling request before replying'
       inputSchema = @{ type = 'object'; properties = @{} } }
)

function Send-Message($obj) {
    $writer.WriteLine((ConvertTo-Json -InputObject $obj -Compress -Depth 20))
}

function Send-Result($id, [hashtable]$result) {
    if ($Mode -eq 'Modern') { $result['resultType'] = 'complete' }
    Send-Message @{ jsonrpc = '2.0'; id = $id; result = $result }
}

function Send-Error($id, [int]$code, [string]$message, $data) {
    $errorBody = @{ code = $code; message = $message }
    if ($null -ne $data) { $errorBody['data'] = $data }
    Send-Message @{ jsonrpc = '2.0'; id = $id; error = $errorBody }
}

function Send-Log([string]$text) {
    Send-Message @{ jsonrpc = '2.0'; method = 'notifications/message'; params = @{ level = 'info'; logger = 'stub'; data = $text } }
}

while ($null -ne ($line = $reader.ReadLine())) {
    if ([string]::IsNullOrWhiteSpace($line)) { continue }

    try {
        $message = ConvertFrom-Json -InputObject $line -AsHashtable -Depth 64
    }
    catch {
        Send-Error $null -32700 'Parse error'
        continue
    }

    $method = $message['method']
    $id = $message['id']
    $params = $message['params']
    if ($null -eq $params) { $params = @{} }

    if ($null -eq $id) {
        $stderr.WriteLine("stub-server: notification $method")
        continue
    }

    # A log notification precedes every response so clients must skip notifications while awaiting a result
    Send-Log "handling $method"

    if ($Mode -eq 'Modern' -and $method -ne 'server/discover') {
        $meta = $params['_meta']
        if ($null -eq $meta -or -not $meta['io.modelcontextprotocol/protocolVersion']) {
            Send-Error $id -32602 "Invalid params: missing _meta protocolVersion (modern server; supported versions: $modernVersion)"
            continue
        }
    }

    switch ($method) {
        'server/discover' {
            switch ($Mode) {
                'Modern' {
                    $requested = $params['_meta']['io.modelcontextprotocol/protocolVersion']
                    if ($requested -ne $modernVersion) {
                        Send-Error $id -32022 'Unsupported protocol version' @{ supported = @($modernVersion); requested = $requested }
                    }
                    else {
                        Send-Result $id @{
                            supportedVersions = @($modernVersion)
                            capabilities      = @{ tools = @{} }
                            _meta             = @{ 'io.modelcontextprotocol/serverInfo' = @{ name = 'stub-server'; version = '1.0.0' } }
                            instructions      = 'Stub server for PSMcpClient tests'
                        }
                    }
                }
                'Legacy' { Send-Error $id -32601 "Method not found: $method" }
                'Silent' { $stderr.WriteLine('stub-server: swallowing server/discover') }
            }
        }
        'initialize' {
            if ($Mode -eq 'Modern') {
                Send-Error $id -32601 "Method not found: initialize (modern server; supported versions: $modernVersion)"
            }
            else {
                Send-Result $id @{
                    protocolVersion = $params['protocolVersion']
                    capabilities    = @{ tools = @{ listChanged = $true } }
                    serverInfo      = @{ name = 'stub-server'; version = '1.0.0' }
                }
            }
        }
        'ping' { Send-Result $id @{} }
        'tools/list' { Send-Result $id @{ tools = $tools } }
        'tools/call' {
            $toolName = $params['name']
            $toolArgs = $params['arguments']
            if ($null -eq $toolArgs) { $toolArgs = @{} }

            switch ($toolName) {
                'echo' { Send-Result $id @{ content = @(@{ type = 'text'; text = (ConvertTo-Json -InputObject $toolArgs -Compress -Depth 10) }) } }
                'fail' { Send-Result $id @{ content = @(@{ type = 'text'; text = "failure: $($toolArgs['reason'])" }); isError = $true } }
                'plain' { Send-Result $id @{ content = @(@{ type = 'text'; text = 'hello world' }) } }
                'multi' { Send-Result $id @{ content = @(@{ type = 'text'; text = 'first' }, @{ type = 'image'; data = 'AAAA'; mimeType = 'image/png' }, @{ type = 'text'; text = 'second' }) } }
                'structured' { Send-Result $id @{ content = @(@{ type = 'text'; text = '{"answer":42}' }); structuredContent = @{ answer = 42; source = 'structured' } } }
                'sleep' {
                    Start-Sleep -Seconds ([double]$toolArgs['seconds'])
                    Send-Result $id @{ content = @(@{ type = 'text'; text = 'awake' }) }
                }
                'notify_changed' {
                    Send-Message @{ jsonrpc = '2.0'; method = 'notifications/tools/list_changed' }
                    Send-Result $id @{ content = @(@{ type = 'text'; text = 'notified' }) }
                }
                'crash' {
                    $stderr.WriteLine('stub-server: crashing on request')
                    exit 3
                }
                'request_sampling' {
                    Send-Message @{ jsonrpc = '2.0'; id = 'srv-1'; method = 'sampling/createMessage'; params = @{ messages = @(); maxTokens = 1 } }
                    $reply = $reader.ReadLine()
                    $replyMessage = ConvertFrom-Json -InputObject $reply -AsHashtable -Depth 16
                    Send-Result $id @{ content = @(@{ type = 'text'; text = "client replied with error code $($replyMessage['error']['code'])" }) }
                }
                default { Send-Error $id -32602 "Unknown tool: $toolName" }
            }
        }
        default { Send-Error $id -32601 "Method not found: $method" }
    }
}

$stderr.WriteLine('stub-server: stdin closed, exiting')
