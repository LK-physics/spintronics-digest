$configPath = Join-Path $PSScriptRoot "config.json"
Write-Host "Reading from: $configPath"

$content = Get-Content -Path $configPath -Raw -Encoding UTF8
Write-Host "Content type: $($content.GetType().Name)"

$config = ConvertFrom-Json -InputObject $content
Write-Host "Config type: $($config.GetType().Name)"
Write-Host "senderEmail: $($config.senderEmail)"

# Try pipeline approach
$config2 = $content | ConvertFrom-Json
Write-Host "Config2 type: $($config2.GetType().Name)"
Write-Host "senderEmail2: $($config2.senderEmail)"
