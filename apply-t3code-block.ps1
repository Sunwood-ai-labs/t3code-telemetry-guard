<#
.SYNOPSIS
    T3 Code テレメトリ無効化・ブロック適用スクリプト
.DESCRIPTION
    1. ユーザー環境変数に以下を永続設定:
       - T3CODE_TELEMETRY_ENABLED=false
       - T3CODE_OTEL_SDK_DISABLED=true
       - OTEL_SDK_DISABLED=true
    2. Windows hosts ファイルにテレメトリ送信先ドメインをブロック追記 (バックアップ作成・冪等):
       - ingest.t3.codes
       - us-east-1.aws.edge.axiom.co
       - api.axiom.co
       - us.i.posthog.com
       - eu.i.posthog.com
    3. DNS キャッシュをフラッシュ (ipconfig /flushdns)
    4. (任意) -IncludeWsl 指定時、WSL の ~/.bashrc / ~/.zshrc にも環境変数を追記
#>
[CmdletBinding()]
param(
    [switch]$SkipHosts,
    [switch]$IncludeWsl
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$BeginMarker = '# BEGIN T3CODE TELEMETRY BLOCK'
$EndMarker   = '# END T3CODE TELEMETRY BLOCK'

$BlockDomains = @(
    'ingest.t3.codes',
    'us-east-1.aws.edge.axiom.co',
    'api.axiom.co',
    'us.i.posthog.com',
    'eu.i.posthog.com'
)

$EnvSettings = [ordered]@{
    'T3CODE_TELEMETRY_ENABLED' = 'false'
    'T3CODE_OTEL_SDK_DISABLED' = 'true'
    'OTEL_SDK_DISABLED'        = 'true'
}

function Test-IsAdmin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

Write-Host ""
Write-Host "=== T3 Code テレメトリ対策パッチ適用 ===" -ForegroundColor Cyan

# 1. ユーザー環境変数の永続設定
Write-Host "`n[1/3] Windows ユーザー環境変数を設定しています..." -ForegroundColor Yellow
foreach ($kv in $EnvSettings.GetEnumerator()) {
    [Environment]::SetEnvironmentVariable($kv.Key, $kv.Value, 'User')
    [Environment]::SetEnvironmentVariable($kv.Key, $kv.Value, 'Process')
    Write-Host ("  [OK] {0}={1}" -f $kv.Key, $kv.Value) -ForegroundColor Green
}

# 2. hosts ファイルへのブロック追記
if (-not $SkipHosts) {
    Write-Host "`n[2/3] hosts ファイルへブロックルールを適用しています..." -ForegroundColor Yellow
    if (-not (Test-IsAdmin)) {
        Write-Host "  [ERROR] hosts ファイルの編集には管理者権限が必要です。" -ForegroundColor Red
        Write-Host "  apply-t3code-block.bat を実行するか、管理者 PowerShell から再実行してください。" -ForegroundColor Yellow
        exit 1
    }

    $hostsPath = "$env:SystemRoot\System32\drivers\etc\hosts"
    $backupPath = "$hostsPath.t3code-guard.bak.$(Get-Date -Format 'yyyyMMdd-HHmmss')"
    Copy-Item -Path $hostsPath -Destination $backupPath -Force
    Write-Host ("  [INFO] バックアップ作成: {0}" -f $backupPath) -ForegroundColor DarkGray

    $rawContent = Get-Content -Path $hostsPath -Raw -Encoding UTF8
    if ($null -eq $rawContent) { $rawContent = '' }

    # 既存のブロックセクションがあれば削除して最新化（冪等）
    $pattern = "(?ms)\r?\n?$([regex]::Escape($BeginMarker)).*?$([regex]::Escape($EndMarker))\r?\n?"
    $cleaned = [regex]::Replace($rawContent, $pattern, "`r`n").TrimEnd()

    $blockLines = New-Object System.Collections.Generic.List[string]
    $blockLines.Add($BeginMarker)
    foreach ($d in $BlockDomains) {
        $blockLines.Add("0.0.0.0 $d")
        $blockLines.Add(":: $d")
    }
    $blockLines.Add($EndMarker)

    $newContent = $cleaned + "`r`n`r`n" + ($blockLines -join "`r`n") + "`r`n"
    [System.IO.File]::WriteAllText($hostsPath, $newContent, (New-Object System.Text.UTF8Encoding($false)))

    foreach ($d in $BlockDomains) {
        Write-Host ("  [OK] ブロック登録: {0}" -f $d) -ForegroundColor Green
    }

    # 3. DNS キャッシュのフラッシュ
    Write-Host "`n[3/3] DNS キャッシュをクリアしています..." -ForegroundColor Yellow
    ipconfig /flushdns | Out-Null
    Write-Host "  [OK] DNS キャッシュをフラッシュしました。" -ForegroundColor Green
} else {
    Write-Host "`n[2/3] -SkipHosts が指定されたため hosts 編集をスキップしました。" -ForegroundColor DarkGray
}

# オプション: WSL シェル設定への追記
if ($IncludeWsl) {
    Write-Host "`n[OPT] WSL の ~/.bashrc / ~/.zshrc に環境変数を追記しています..." -ForegroundColor Yellow
    $wslCmd = @'
for rc in "$HOME/.bashrc" "$HOME/.zshrc"; do
  if [ -f "$rc" ]; then
    if ! grep -q "BEGIN T3CODE TELEMETRY BLOCK" "$rc"; then
      cat << 'EOF' >> "$rc"

# BEGIN T3CODE TELEMETRY BLOCK
export T3CODE_TELEMETRY_ENABLED=false
export T3CODE_OTEL_SDK_DISABLED=true
export OTEL_SDK_DISABLED=true
# END T3CODE TELEMETRY BLOCK
EOF
      echo "Updated $rc"
    else
      echo "Already configured: $rc"
    fi
  fi
done
'@
    try {
        wsl.exe bash -lc $wslCmd
    } catch {
        Write-Host "  [WARN] WSL への適用をスキップしました: $_" -ForegroundColor Yellow
    }
}

Write-Host "`n=== 完了 ===" -ForegroundColor Cyan
Write-Host "  ※ すでに起動中の T3 Code やターミナルがある場合は、環境変数を反映するため再起動してください。" -ForegroundColor Yellow
Write-Host "  ※ 続けて verify-t3code-telemetry.bat を実行してブロック状態を確認できます。" -ForegroundColor Gray
Write-Host ""
