<#
.SYNOPSIS
    T3 Code テレメトリ送信状態の現状診断・ライブ監視スクリプト
.DESCRIPTION
    1. 環境変数 (T3CODE_TELEMETRY_ENABLED / T3CODE_OTEL_SDK_DISABLED / OTEL_SDK_DISABLED) の設定確認
    2. ローカルの T3 Code 導入状況・識別ファイル・クロスツール参照対象 (~/.codex/auth.json, ~/.claude.json) の確認
    3. hosts ファイルおよび実際の DNS 解決結果によるブロック確認
    4. DNS キャッシュ履歴 (直近の送信痕跡) およびアクティブ TCP 接続の確認
    5. -WatchSeconds 指定時、指定秒数のあいだ通信・DNS解決の発生をリアルタイム監視
.EXAMPLE
    .\verify-t3code-telemetry.ps1
    .\verify-t3code-telemetry.ps1 -WatchSeconds 30
#>
[CmdletBinding()]
param(
    [int]$WatchSeconds = 0
)

$ErrorActionPreference = 'SilentlyContinue'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$TelemetryDomains = @(
    'ingest.t3.codes',
    'us-east-1.aws.edge.axiom.co',
    'api.axiom.co',
    'us.i.posthog.com',
    'eu.i.posthog.com'
)

$EnvVars = @(
    @{ Name = 'T3CODE_TELEMETRY_ENABLED'; Expected = 'false' },
    @{ Name = 'T3CODE_OTEL_SDK_DISABLED'; Expected = 'true'  },
    @{ Name = 'OTEL_SDK_DISABLED';        Expected = 'true'  }
)

function Write-Section([string]$Title) {
    Write-Host ""
    Write-Host ("=" * 68) -ForegroundColor DarkCyan
    Write-Host "  $Title" -ForegroundColor Cyan
    Write-Host ("=" * 68) -ForegroundColor DarkCyan
}

function Write-Badge([string]$Level, [string]$Message) {
    switch ($Level) {
        'OK'   { Write-Host "  [OK]   " -ForegroundColor Green  -NoNewline; Write-Host $Message }
        'WARN' { Write-Host "  [WARN] " -ForegroundColor Yellow -NoNewline; Write-Host $Message }
        'RISK' { Write-Host "  [RISK] " -ForegroundColor Red    -NoNewline; Write-Host $Message }
        default{ Write-Host "  [INFO] " -ForegroundColor Gray   -NoNewline; Write-Host $Message }
    }
}

$riskCount = 0
$warnCount = 0

# スクリプト自身の DNS 解決でキャッシュが汚染される前に、初期の DNS キャッシュを取得
$initialDnsCache = Get-DnsClientCache | Where-Object {
    $_.Entry -match 't3\.codes|axiom\.co|posthog\.com'
}

Write-Host ""
Write-Host "T3 Code Telemetry Verification Tool" -ForegroundColor White
Write-Host ("Timestamp: " + (Get-Date -Format "yyyy-MM-dd HH:mm:ss")) -ForegroundColor DarkGray

# ------------------------------------------------------------------
# 1. 環境変数チェック
# ------------------------------------------------------------------
Write-Section "1. 環境変数チェック (オプトアウト設定)"

foreach ($v in $EnvVars) {
    $name = $v.Name
    $expected = $v.Expected
    $procVal = [Environment]::GetEnvironmentVariable($name, 'Process')
    $userVal = [Environment]::GetEnvironmentVariable($name, 'User')
    $machVal = [Environment]::GetEnvironmentVariable($name, 'Machine')

    $effective = if ($procVal) { $procVal } elseif ($userVal) { $userVal } elseif ($machVal) { $machVal } else { $null }

    if ($effective -and $effective.ToLower() -eq $expected) {
        $persisted = ($userVal -and $userVal.ToLower() -eq $expected) -or ($machVal -and $machVal.ToLower() -eq $expected)
        if ($persisted) {
            $uDisp = if ($userVal) { $userVal } else { '' }
            $mDisp = if ($machVal) { $machVal } else { '' }
            Write-Badge 'OK' ("{0}={1} (User='{2}', Machine='{3}')" -f $name, $effective, $uDisp, $mDisp)
        } else {
            Write-Badge 'WARN' ("{0}={1} (現在プロセスのみ有効。永続化されていません)" -f $name, $effective)
            $warnCount++
        }
    } else {
        $eDisp = if ($effective) { $effective } else { '<未設定>' }
        Write-Badge 'RISK' ("{0} は未設定または無効値です (現在値='{1}', 推奨='{2}')" -f $name, $eDisp, $expected)
        $riskCount++
    }
}

# ------------------------------------------------------------------
# 2. T3 Code インストール＆ローカル識別子チェック
# ------------------------------------------------------------------
Write-Section "2. ローカル T3 Code 導入・識別ファイル確認"

$t3ExeCandidates = @(
    "$env:LOCALAPPDATA\Programs\t3code\T3 Code (Nightly).exe",
    "$env:LOCALAPPDATA\Programs\t3code\T3 Code.exe",
    "$env:ProgramFiles\T3 Code\T3 Code.exe"
)
$foundExe = $t3ExeCandidates | Where-Object { Test-Path $_ }
if ($foundExe) {
    foreach ($exe in $foundExe) {
        $item = Get-Item $exe
        Write-Badge 'INFO' ("検出バイナリ: {0} (更新日時: {1})" -f $exe, $item.LastWriteTime.ToString("yyyy-MM-dd HH:mm"))
    }
} else {
    Write-Badge 'INFO' "標準パスに T3 Code の実行ファイルは見つかりませんでした。"
}

$t3Artifacts = @(
    @{ Path = "$env:USERPROFILE\.t3\userdata\anonymous-id";   Desc = "T3 Code 匿名IDファイル" },
    @{ Path = "$env:USERPROFILE\.t3\usage-host-id";           Desc = "T3 Code ホスト識別IDファイル" },
    @{ Path = "$env:USERPROFILE\.t3\userdata\environment-id"; Desc = "T3 Code 環境IDファイル" },
    @{ Path = "$env:USERPROFILE\.codex\auth.json";            Desc = "Codex 認証ファイル (Identify.ts 参照対象)" },
    @{ Path = "$env:USERPROFILE\.claude.json";                Desc = "Claude Code 設定ファイル (Identify.ts 参照対象)" }
)

foreach ($a in $t3Artifacts) {
    if (Test-Path $a.Path) {
        $fi = Get-Item $a.Path
        Write-Badge 'WARN' ("存在: {0} ({1}, 更新: {2})" -f $a.Path, $a.Desc, $fi.LastWriteTime.ToString("yyyy-MM-dd HH:mm"))
    } else {
        Write-Badge 'INFO' ("なし: {0}" -f $a.Path)
    }
}

# ------------------------------------------------------------------
# 3. hosts & DNS 解決チェック
# ------------------------------------------------------------------
Write-Section "3. hosts ブロック & DNS 解決チェック"

$hostsPath = "$env:SystemRoot\System32\drivers\etc\hosts"
$hostsLines = if (Test-Path $hostsPath) { Get-Content $hostsPath } else { @() }

$resolvedExternalIps = @{}

foreach ($domain in $TelemetryDomains) {
    $escaped = [regex]::Escape($domain)
    $inHosts = $hostsLines | Where-Object { $_ -match "^\s*(0\.0\.0\.0|127\.0\.0\.1|::1?)\s+.*\b$escaped\b" }

    $addrs = @()
    try {
        $addrs = [System.Net.Dns]::GetHostAddresses($domain) | ForEach-Object { $_.IPAddressToString }
    } catch {
        $addrs = @()
    }

    $isBlocked = ($addrs.Count -gt 0) -and ($addrs | Where-Object { $_ -notin @('0.0.0.0', '127.0.0.1', '::', '::1') }).Count -eq 0

    if ($inHosts -and $isBlocked) {
        Write-Badge 'OK' ("{0} -> ブロック済み (DNS解決: {1})" -f $domain, ($addrs -join ', '))
    } elseif ($inHosts -and -not $isBlocked) {
        Write-Badge 'WARN' ("{0} -> hosts に記載あり、ただし DNS キャッシュまたは別解決が残存 (解決: {1})。ipconfig /flushdns を推奨" -f $domain, ($addrs -join ', '))
        $warnCount++
        foreach ($ip in $addrs) { $resolvedExternalIps[$ip] = $domain }
    } else {
        $ipStr = if ($addrs.Count -gt 0) { $addrs -join ', ' } else { '<解決失敗>' }
        Write-Badge 'RISK' ("{0} -> 未ブロック (外部IPへ到達可能: {1})" -f $domain, $ipStr)
        $riskCount++
        foreach ($ip in $addrs) {
            if ($ip -notin @('0.0.0.0', '127.0.0.1', '::', '::1')) {
                $resolvedExternalIps[$ip] = $domain
            }
        }
    }
}

# ------------------------------------------------------------------
# 4. DNS キャッシュ履歴 (直近の送信痕跡) & 実行中プロセス・TCP 接続
# ------------------------------------------------------------------
Write-Section "4. 直近の送信痕跡 (DNS キャッシュ) & アクティブ接続チェック"

$dnsCache = $initialDnsCache

if ($dnsCache) {
    foreach ($entry in $dnsCache) {
        $isBlockedIp = $entry.Data -in @('0.0.0.0', '127.0.0.1', '::', '::1')
        if ($isBlockedIp) {
            Write-Badge 'OK' ("DNSキャッシュ: {0} -> {1} (ブロック応答)" -f $entry.Entry, $entry.Data)
        } else {
            Write-Badge 'RISK' ("DNSキャッシュに外部解決の履歴あり: {0} -> {1} (TTL: {2}s) ※直近で名前解決が発生" -f $entry.Entry, $entry.Data, $entry.TimeToLive)
            $warnCount++
        }
    }
} else {
    Write-Badge 'INFO' "DNS キャッシュにテレメトリドメインの直近履歴はありません (未起動または TTL 切れ)。"
}

$t3Procs = Get-Process | Where-Object { $_.ProcessName -match 't3\s*code|t3code' }
if ($t3Procs) {
    Write-Badge 'INFO' ("実行中の T3 Code プロセス数: {0} (PID: {1})" -f $t3Procs.Count, (($t3Procs.Id) -join ', '))
    $t3Pids = $t3Procs.Id
    $conns = Get-NetTCPConnection | Where-Object { $_.OwningProcess -in $t3Pids -and $_.RemoteAddress -notin @('127.0.0.1', '::1', '0.0.0.0', '::') }
    if ($conns) {
        foreach ($c in $conns) {
            $matchedDomain = $resolvedExternalIps[$c.RemoteAddress]
            if ($matchedDomain) {
                Write-Badge 'RISK' ("アクティブ送信接続を検出! PID={0} -> {1}:{2} ({3}) [{4}]" -f $c.OwningProcess, $c.RemoteAddress, $c.RemotePort, $matchedDomain, $c.State)
                $riskCount++
            } else {
                Write-Badge 'INFO' ("T3 Code 外部接続: PID={0} -> {1}:{2} [{3}]" -f $c.OwningProcess, $c.RemoteAddress, $c.RemotePort, $c.State)
            }
        }
    } else {
        Write-Badge 'INFO' "T3 Code プロセスからの外部 TCP 接続は現在検出されませんでした。"
    }
} else {
    Write-Badge 'INFO' "現在、T3 Code プロセスは起動していません。"
}

# ------------------------------------------------------------------
# 5. 過去の送信記録スキャン (ローカルログ & Electron ネットワーク履歴)
# ------------------------------------------------------------------
Write-Section "5. 過去の送信記録 (ローカルログ & Electron 接続履歴)"

$npsPath = "$env:APPDATA\t3code-v2\Network\Network Persistent State"
if (Test-Path $npsPath) {
    $npsRaw = Get-Content $npsPath -Raw -ErrorAction SilentlyContinue
    $npsHits = [regex]::Matches($npsRaw, 'https?://[a-z0-9.-]*(ingest\.t3\.codes|axiom\.co|posthog\.com)[a-z0-9./_-]*') |
        ForEach-Object { $_.Value } | Sort-Object -Unique
    if ($npsHits) {
        foreach ($u in $npsHits) {
            Write-Badge 'WARN' ("Electron 接続履歴に記録あり: {0} ({1})" -f $u, $npsPath)
        }
    } else {
        Write-Badge 'INFO' "Electron Network Persistent State にテレメトリ送信先への接続履歴はありません。"
    }
}

$traceFiles = Get-ChildItem "$env:USERPROFILE\.t3\userdata\logs\server.trace.ndjson*" -File -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Descending
$sendRecords = New-Object System.Collections.Generic.List[string]
foreach ($tf in $traceFiles) {
    $matches = Select-String -Path $tf.FullName -Pattern 'ingest\.t3\.codes|AnalyticsService\.sendBatch' -SimpleMatch:$false
    foreach ($m in $matches) {
        try {
            $obj = $m.Line | ConvertFrom-Json
            if ($obj.name -eq 'POST' -and $obj.attributes.'url.full' -match 'ingest\.t3\.codes') {
                $tsSec = [double]$obj.startTimeUnixNano / 1000000000.0
                $dtLocal = [DateTimeOffset]::FromUnixTimeSeconds([long]$tsSec).ToLocalTime().ToString("yyyy-MM-dd HH:mm:ss")
                $status = $obj.attributes.'http.response.status_code'
                $exitTag = $obj.exit._tag
                $sendRecords.Add(("{0} | POST {1} -> HTTP {2} ({3}) [{4}:L{5}]" -f $dtLocal, $obj.attributes.'url.full', $status, $exitTag, $tf.Name, $m.LineNumber))
            }
        } catch {}
    }
}

if ($sendRecords.Count -gt 0) {
    Write-Badge 'WARN' ("サーバーログから過去のテレメトリ POST 送信記録を {0} 件検出:" -f $sendRecords.Count)
    foreach ($r in ($sendRecords | Select-Object -First 10)) {
        Write-Host ("         -> {0}" -f $r) -ForegroundColor Yellow
    }
} else {
    Write-Badge 'INFO' "現在の server.trace.ndjson* に ingest.t3.codes への POST 記録はありません。"
}

# ------------------------------------------------------------------
# 6. ライブ監視モード (オプション)
# ------------------------------------------------------------------
if ($WatchSeconds -gt 0) {
    Write-Section ("6. ライブ監視モード ({0} 秒間)" -f $WatchSeconds)
    Write-Host "  T3 Code を起動・操作すると、テレメトリ送信試行 (DNS解決 / TCP接続) を検知します..." -ForegroundColor Yellow

    $seen = @{}
    $endTime = (Get-Date).AddSeconds($WatchSeconds)
    while ((Get-Date) -lt $endTime) {
        $cacheHits = Get-DnsClientCache | Where-Object { $_.Entry -match 'ingest\.t3\.codes|axiom\.co|posthog\.com' }
        foreach ($h in $cacheHits) {
            $key = "DNS:$($h.Entry)->$($h.Data)"
            if (-not $seen.ContainsKey($key)) {
                $seen[$key] = $true
                $ts = Get-Date -Format "HH:mm:ss"
                if ($h.Data -in @('0.0.0.0', '127.0.0.1', '::', '::1')) {
                    Write-Host ("  [{0}] [BLOCKED] DNS試行をブロック: {1} -> {2}" -f $ts, $h.Entry, $h.Data) -ForegroundColor Green
                } else {
                    Write-Host ("  [{0}] [DETECTED] 外部DNS解決を検出: {1} -> {2}" -f $ts, $h.Entry, $h.Data) -ForegroundColor Red
                    $resolvedExternalIps[$h.Data] = $h.Entry
                }
            }
        }

        $procs = Get-Process | Where-Object { $_.ProcessName -match 't3\s*code|t3code' }
        if ($procs) {
            $pids = $procs.Id
            $liveConns = Get-NetTCPConnection | Where-Object {
                $_.OwningProcess -in $pids -and $_.RemoteAddress -notin @('127.0.0.1', '::1', '0.0.0.0', '::')
            }
            foreach ($lc in $liveConns) {
                $key = "TCP:$($lc.OwningProcess):$($lc.RemoteAddress):$($lc.RemotePort):$($lc.State)"
                if (-not $seen.ContainsKey($key)) {
                    $seen[$key] = $true
                    $ts = Get-Date -Format "HH:mm:ss"
                    $dom = $resolvedExternalIps[$lc.RemoteAddress]
                    if ($dom) {
                        Write-Host ("  [{0}] [ALERT] テレメトリ接続を検出! PID={1} -> {2}:{3} ({4}) [{5}]" -f $ts, $lc.OwningProcess, $lc.RemoteAddress, $lc.RemotePort, $dom, $lc.State) -ForegroundColor Red
                    } else {
                        Write-Host ("  [{0}] [TCP] T3 Code 外部接続: PID={1} -> {2}:{3} [{4}]" -f $ts, $lc.OwningProcess, $lc.RemoteAddress, $lc.RemotePort, $lc.State) -ForegroundColor DarkYellow
                    }
                }
            }
        }
        Start-Sleep -Milliseconds 1000
    }
    Write-Host "  ライブ監視が終了しました。" -ForegroundColor Cyan
}

# ------------------------------------------------------------------
# 総合判定
# ------------------------------------------------------------------
Write-Section "総合判定"
if ($riskCount -eq 0 -and $warnCount -eq 0) {
    Write-Host "  [PROTECTED] 環境変数オプトアウト + hosts ブロックの両方が有効です。" -ForegroundColor Green
} elseif ($riskCount -eq 0) {
    Write-Host ("  [PARTIALLY PROTECTED] 致命的リスクはありませんが、確認事項が {0} 件あります。" -f $warnCount) -ForegroundColor Yellow
} else {
    Write-Host ("  [AT RISK] テレメトリが送信され得る状態です (リスク: {0} 件 / 警告: {1} 件)。" -f $riskCount, $warnCount) -ForegroundColor Red
    Write-Host "  -> apply-t3code-block.bat を実行して環境変数設定と hosts ブロックを適用してください。" -ForegroundColor Yellow
}
Write-Host ""
