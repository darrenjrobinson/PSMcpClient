$script:Sessions = @{}
$script:LegacyProtocolVersion = '2025-11-25'
$script:ModernProtocolVersion = '2026-07-28'
$script:DefaultInitializeTimeoutSec = 120
$script:DefaultRequestTimeoutSec = 30
$script:ExitHandlerRegistered = $false

$manifest = Import-PowerShellDataFile -Path "$PSScriptRoot/PSMcpClient.psd1"
$script:ClientInfo = @{
    name    = 'PSMcpClient'
    version = [string]$manifest.ModuleVersion
}

foreach ($file in Get-ChildItem -Path "$PSScriptRoot/Private/*.ps1", "$PSScriptRoot/Public/*.ps1" -ErrorAction Stop) {
    . $file.FullName
}

$ExecutionContext.SessionState.Module.OnRemove = {
    Disconnect-McpServer -All -ErrorAction SilentlyContinue -WarningAction SilentlyContinue
}

Export-ModuleMember -Function (Get-ChildItem -Path "$PSScriptRoot/Public/*.ps1").BaseName
