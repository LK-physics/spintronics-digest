$configPath = Join-Path $PSScriptRoot "config.json"
$content = Get-Content -Path $configPath -Raw -Encoding UTF8
Write-Host "Raw content:"
Write-Host $content
Write-Host ""
Write-Host "Parsed:"
$config = $content | ConvertFrom-Json
Write-Host "smtpServer: $($config.smtpServer)"
Write-Host "smtpPort: $($config.smtpPort)"
Write-Host "senderEmail: $($config.senderEmail)"
Write-Host "senderPassword: $($config.senderPassword)"
Write-Host "recipientEmail: $($config.recipientEmail)"
