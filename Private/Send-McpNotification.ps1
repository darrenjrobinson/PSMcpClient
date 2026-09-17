function Send-McpNotification {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Session,
        [Parameter(Mandatory)][string]$Method,
        [System.Collections.IDictionary]$Params
    )

    $message = [ordered]@{ jsonrpc = '2.0'; method = $Method }
    if ($Params) { $message.params = $Params }

    Write-McpMessage -Session $Session -Message $message
}
