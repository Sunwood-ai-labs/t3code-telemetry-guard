# t3code-telemetry-guard

Windows 環境で **T3 Code (`pingdotgg/t3code`)** のテレメトリ送信状態を検証し、**環境変数オプトアウト ＋ `hosts` ブロック** の二重対策で遮断・ロールバックできる PowerShell / バッチファイル集です。

## なぜ二重ブロックが必要か

実機検証（T3 Code Nightly `0.1.12`）で確認した挙動：

- デフォルトでは `https://ingest.t3.codes/batch/` へのバッチ送信（PostHog 互換）や Axiom（`us-east-1.aws.edge.axiom.co`）への診断トレース接続が行われます。
- `T3CODE_TELEMETRY_ENABLED=false` を設定して再起動すると **外部送信（`sendBatch`）自体は停止** します。
- ただし、初期化時の `getTelemetryIdentity` / `getServerOwnersForHome` は環境変数を見ずに実行され、`~/.codex/auth.json` と `~/.claude.json` の読み込み・ハッシュ生成自体は起動のたびに走ります。
- 起動経路の違いによる環境変数抜けやブラウザ側 Axiom 通信も防ぐため、**環境変数の永続設定 ＋ `hosts` によるドメイン遮断** の併用を推奨します。

## ファイル一覧

| ファイル | 用途 | 管理者権限 |
|---|---|---|
| `verify-t3code-telemetry.bat` / `.ps1` | 現状診断・過去送信ログ検出・ライブ通信監視 | 不要 |
| `apply-t3code-block.bat` / `.ps1` | 環境変数の永続設定 ＋ `hosts` ブロック ＋ DNS フラッシュ | 必要（`.bat` は自動で UAC 昇格） |
| `revert-t3code-block.bat` / `.ps1` | 追加した環境変数と `hosts` ブロックのみを元に戻す | 必要（`.bat` は自動で UAC 昇格） |

## 使い方

### 1. 現状を検証する（読み取り専用）

`verify-t3code-telemetry.bat` をダブルクリック、または PowerShell から実行します。

```powershell
.\verify-t3code-telemetry.ps1
```

チェック内容：
1. 環境変数（`T3CODE_TELEMETRY_ENABLED` / `T3CODE_OTEL_SDK_DISABLED` / `OTEL_SDK_DISABLED`）
2. T3 Code 導入状況・識別ファイル・クロスツール参照対象（`~/.codex/auth.json`, `~/.claude.json`）
3. `hosts` 記載および実際の DNS 解決結果
4. DNS キャッシュ履歴・起動中プロセスのアクティブ TCP 接続
5. ローカルログ（`~/.t3/userdata/logs/server.trace.ndjson*`）および Electron `Network Persistent State` に残る過去の送信履歴

T3 Code を操作しながらリアルタイムで DNS 解決・TCP 接続を監視したい場合：

```powershell
.\verify-t3code-telemetry.ps1 -WatchSeconds 30
```

### 2. 二重ブロックを適用する

`apply-t3code-block.bat` をダブルクリックします（UAC 確認が表示されます）。

実施内容：
1. **Windows ユーザー環境変数** へ以下を永続登録：
   - `T3CODE_TELEMETRY_ENABLED=false`
   - `T3CODE_OTEL_SDK_DISABLED=true`
   - `OTEL_SDK_DISABLED=true`
2. **`C:\Windows\System32\drivers\etc\hosts`** のタイムスタンプ付きバックアップを作成したうえで、専用マーカー（`# BEGIN T3CODE TELEMETRY BLOCK` 〜 `# END T3CODE TELEMETRY BLOCK`）内に以下を `0.0.0.0` / `::` として追記：
   - `ingest.t3.codes`
   - `us-east-1.aws.edge.axiom.co`
   - `api.axiom.co`
   - `us.i.posthog.com`
   - `eu.i.posthog.com`
3. **`ipconfig /flushdns`** を実行して DNS キャッシュをクリア。

WSL の `~/.bashrc` / `~/.zshrc` にも同じ環境変数を追記したい場合：

```powershell
.\apply-t3code-block.ps1 -IncludeWsl
```

> **重要**: 適用後、すでに起動している T3 Code やターミナルは **完全に終了して再起動** してください。その後 `verify-t3code-telemetry.bat` を再実行し、総合判定が `[PROTECTED]` になることを確認します。

### 3. 元に戻す（ロールバック）

`revert-t3code-block.bat` をダブルクリックすると、このツールが追加したユーザー環境変数 3 種と `hosts` のマーカー範囲のみを削除し、DNS キャッシュをフラッシュします。

## 動作環境

- Windows 10 / 11（Windows PowerShell 5.1 / PowerShell 7+ 対応）

## License

MIT
