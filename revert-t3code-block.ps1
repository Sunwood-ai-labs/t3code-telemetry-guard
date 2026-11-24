<#
.SYNOPSIS
    T3 Code テレメトリ対策パッチを元に戻す（ロールバック）スクリプト
#>
[CmdletBinding()]
param(
    [switch]$SkipHosts
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$BeginMarker = '# BEGIN T3CODE TELEMETRY BLOCK'
$EndMarker   = '# END T3CODE TELEMETRY BLOCK'

$EnvNames = @(
    'T3CODE_TELEMETRY_ENABLED',
    'T3CODE_OTEL_SDK_DISABLED',
    'OTEL_SDK_DISABLED'
)

function Test-IsAdmin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

Write-Host ""
Write-Host "=== T3 Code テレメトリ対策パッチの解除 (ロールバック) ===" -ForegroundColor Cyan

Write-Host "`n[1/2] Windows ユーザー環境変数を削除しています..." -ForegroundColor Yellow
foreach ($name in $EnvNames) {
    [Environment]::SetEnvironmentVariable($name, $null, 'User')
    [Environment]::SetEnvironmentVariable($name, $null, 'Process')
    Write-Host ("  [OK] 削除: {0}" -f $name) -ForegroundColor Green
}

if (-not $SkipHosts) {
    Write-Host "`n[2/2] hosts ファイルからブロックルールを削除しています..." -ForegroundColor Yellow
    if (-not (Test-IsAdmin)) {
        Write-Host "  [ERROR] hosts ファイルの編集には管理者権限が必要です。" -ForegroundColor Red
        exit 1
    }

    $hostsPath = "$env:SystemRoot\System32\drivers\etc\hosts"
    $rawContent = Get-Content -Path $hostsPath -Raw -Encoding UTF8
    if ($null -ne $rawContent) {
        $pattern = "(?ms)\r?\n?$([regex]::Escape($BeginMarker)).*?$([regex]::Escape($EndMarker))\r?\n?"
        $cleaned = [regex]::Replace($rawContent, $pattern, "`r`n").TrimEnd() + "`r`n"
        [System.IO.File]::WriteAllText($hostsPath, $cleaned, (New-Object System.Text.UTF8Encoding($false)))
        Write-Host "  [OK] hosts のブロックセクションを削除しました。" -ForegroundColor Green
    }

    ipconfig /flushdns | Out-Null
    Write-Host "  [OK] DNS キャッシュをフラッシュしました。" -ForegroundColor Green
}

Write-Host "`n=== ロールバック完了 ===" -ForegroundColor Cyan
Write-Host ""
