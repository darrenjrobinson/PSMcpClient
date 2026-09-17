function Receive-McpNotification {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Session,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Message
    )

    $name = $Session.Name
    switch ($Message.method) {
        'notifications/tools/list_changed' {
            $Session.ToolsStale = $true
            Write-Verbose "[$name] tools/list_changed received; tool cache marked stale"
        }
        'notifications/message' {
            $level = $Message.params.level
            $data = $Message.params.data
            $rendered = if ($data -is [string]) { $data } elseif ($null -ne $data) { ConvertTo-Json -InputObject $data -Compress -Depth 10 } else { '' }
            Write-Verbose "[$name] server log [$level] $rendered"
        }
        default {
            Write-Verbose "[$name] ignoring notification '$($Message.method)'"
        }
    }
}
