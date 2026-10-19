# APIGatewayTokenGet

Amazon Cognito ユーザープールのトークンエンドポイントから **M2M 認証 (OAuth 2.0 client_credentials グラント)** 用のアクセストークンを取得し、
**Apache JMeter の HTTP ヘッダマネージャでそのまま使える形式**でファイルに出力するシェルスクリプトです。

- クライアント ID / クライアントシークレット / トークンエンドポイント URL / グラントタイプ / カスタムスコープをパラメータで指定
- アクセストークン (JWT) をデコードし、有効期限などのメタデータを画面に表示
- メタデータはトークンファイルとは別に、**同じベース名**の `.meta.json` ファイルへ出力
- RHEL 9.x (9.8 を想定) の標準的なコマンド (bash / coreutils / curl / jq) のみで動作

## 動作環境

| 項目 | 内容 |
| --- | --- |
| OS | Red Hat Enterprise Linux 9.x |
| シェル | bash 5.1 以上 (RHEL 9 標準) |
| コマンド | `curl`, `jq` (1.6 以上), coreutils (`base64`, `date`, `sha256sum`, `mktemp` など) |

`jq` が未インストールの場合は以下でインストールしてください。

```bash
sudo dnf install -y curl jq
```

テストを実行する場合は `python3` も使用します (RHEL 9 では標準で導入済み)。

## Cognito 側の前提

- ユーザープールにドメイン (Cognito ドメインまたはカスタムドメイン) が設定されていること
- **クライアントシークレットあり**のアプリクライアントで、OAuth フロー「クライアント認証情報 (client_credentials)」が有効であること
- リソースサーバーとカスタムスコープ (例: `my-api/read`) が作成され、アプリクライアントに許可されていること

## 使い方

```bash
chmod +x get_cognito_token.sh

./get_cognito_token.sh \
  -c 1example23456789abcdefghij \
  -s 'xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx' \
  -u https://example.auth.ap-northeast-1.amazoncognito.com/oauth2/token \
  -g client_credentials \
  -S "my-api/read my-api/write" \
  -o /opt/jmeter/tokens
```

### パラメータ

| オプション | 必須 | 説明 | 環境変数 |
| --- | :---: | --- | --- |
| `-c`, `--client-id ID` | ○ | アプリクライアント ID | `COGNITO_CLIENT_ID` |
| `-s`, `--client-secret SECRET` | ○ ※1 | クライアントシークレット | `COGNITO_CLIENT_SECRET` |
| `--client-secret-file FILE` | ○ ※1 | クライアントシークレットをファイルの 1 行目から読み込む | |
| `-u`, `--token-url URL` | ○ | トークンエンドポイント URL。パスを省略すると `/oauth2/token` を補完 | `COGNITO_TOKEN_URL` |
| `-o`, `--output-dir DIR` | ○ | 出力先ディレクトリ (無ければ作成) | `TOKEN_OUTPUT_DIR` |
| `-g`, `--grant-type TYPE` | | グラントタイプ (既定: `client_credentials`)。`clientcredentials` / `client-credentials` も可 | `COGNITO_GRANT_TYPE` |
| `-S`, `--scope SCOPE` | | カスタムスコープ。スペース区切りで複数指定可、オプションの複数回指定も可。省略時はクライアントに許可された全スコープ | `COGNITO_SCOPE` |
| `-n`, `--name NAME` | | 出力ファイル名のプレフィックス (既定: `cognito_token`、英数字 `.` `_` `-` のみ) | |
| `-f`, `--format FORMAT` | | トークンファイルの形式 `raw` / `properties` / `csv` (既定: `raw`) | |
| `-a`, `--auth-method METHOD` | | クライアント認証方式 `basic` (Authorization ヘッダ) / `post` (リクエストボディ) (既定: `basic`) | |
| `--no-timestamp` | | タイムスタンプなしの固定ファイル名で上書き出力 | |
| `--keep N` | | タイムスタンプ付きファイルを新しい順に N 世代だけ残す (既定: 0 = 削除しない) | |
| `--cacert FILE` | | サーバ証明書の検証に使う CA 証明書バンドル (社内プロキシ環境など) | |
| `--connect-timeout SEC` | | 接続タイムアウト秒数 (既定: 10) | |
| `--max-time SEC` | | リクエスト全体のタイムアウト秒数 (既定: 30) | |
| `--retry N` | | 一時的なエラー時のリトライ回数 (既定: 0) | |
| `--show-token` | | アクセストークン全文を画面に表示 (既定は先頭と末尾のみ) | |
| `-q`, `--quiet` | | 画面表示を抑止し、トークンファイルのパスのみ標準出力に出力 | |
| `-h`, `--help` / `-V`, `--version` | | ヘルプ / バージョン表示 | |

※1 シークレットは `-s` → `--client-secret-file` → 環境変数 `COGNITO_CLIENT_SECRET` の順で決定し、いずれも無く端末から実行した場合は対話入力になります。
`-s` で渡した値は同じサーバの他ユーザーから `ps` で見える可能性があるため、共用サーバでは `--client-secret-file` (パーミッション 600) か環境変数の利用を推奨します。
なお、スクリプト内部では curl へのシークレット受け渡しを標準入力経由で行っており、curl のプロセス引数には含まれません。

## 出力ファイル

アクセストークンとメタデータは**同じベース名 (`<NAME>_<取得日時>`) で拡張子だけが異なる**ペアとして出力されます。

```
/opt/jmeter/tokens/
├── cognito_token_20261020_071722.token        … アクセストークン
├── cognito_token_20261020_071722.meta.json    … 上記トークンのメタデータ
├── cognito_token_latest.token     -> cognito_token_20261020_071722.token
└── cognito_token_latest.meta.json -> cognito_token_20261020_071722.meta.json
```

- `*_latest.*` は最新のペアを指すシンボリックリンクです。JMeter からはこのパスを参照すると、トークンを再取得してもテスト計画を変更する必要がありません。
- `--no-timestamp` 指定時は `cognito_token.token` / `cognito_token.meta.json` の固定名で上書きします (リンクは作成しません)。
- 同じ秒に複数回実行した場合は `_2`, `_3` … の連番を付与し、既存ファイルは上書きしません。
- メタデータ内の `files.token_file` に対応するトークンファイル名、`token_fingerprint.sha256` にトークンの SHA-256 を記録しているため、
  ファイル名を変更した場合でも `sha256sum` で対応関係を確認できます。
- ファイルはパーミッション 600、新規作成するディレクトリは 700 で作成します。書き込みは一時ファイル経由で行い、JMeter が読み込み中でも中途半端な内容を読ませません。

### トークンファイルの形式 (`--format`)

| 形式 | 拡張子 | 内容 |
| --- | --- | --- |
| `raw` (既定) | `.token` | アクセストークン文字列のみ (**末尾改行なし**) |
| `properties` | `.properties` | JMeter プロパティファイル (`access_token` / `token_type` / `authorization` / `token_expires_at_epoch`) |
| `csv` | `.csv` | CSV Data Set Config 用 (1 行目がヘッダ: `access_token,token_type,authorization,expires_at_epoch`) |

### メタデータファイル (`.meta.json`)

クライアントシークレットとトークン本体は含みません。

```json
{
  "meta_version": 1,
  "generator": "get_cognito_token.sh 1.0.0",
  "files": {
    "token_file": "cognito_token_20261020_071722.token",
    "token_file_path": "/opt/jmeter/tokens/cognito_token_20261020_071722.token",
    "token_format": "raw",
    "metadata_file": "cognito_token_20261020_071722.meta.json",
    "latest_token_link": "/opt/jmeter/tokens/cognito_token_latest.token",
    "...": "..."
  },
  "token_fingerprint": { "sha256": "60caa67f...", "length": 1043, "jti": "3791439f-..." },
  "request":  { "token_url": "https://...", "grant_type": "client_credentials", "client_id": "...", "client_auth_method": "client_secret_basic", "requested_scope": "my-api/read my-api/write" },
  "response": { "http_status": 200, "token_type": "Bearer", "expires_in": 3600 },
  "acquired_at": { "epoch": 1792448242, "local": "2026-10-20T07:17:22+09:00", "utc": "2026-10-19T22:17:22Z" },
  "validity": {
    "issued_at":  { "epoch": 1792448242, "local": "2026-10-20T07:17:22+09:00", "utc": "2026-10-19T22:17:22Z" },
    "expires_at": { "epoch": 1792451842, "local": "2026-10-20T08:17:22+09:00", "utc": "2026-10-19T23:17:22Z" },
    "lifetime_seconds": 3600,
    "remaining_seconds_at_acquisition": 3600
  },
  "claims_summary": { "iss": "...", "client_id": "...", "token_use": "access", "scope": "my-api/read my-api/write", "scopes": ["my-api/read", "my-api/write"], "jti": "...", "kid": "...", "alg": "RS256", "...": "..." },
  "jwt": { "signature_verified": false, "header": { "...": "..." }, "payload": { "...": "..." } },
  "jmeter": { "header_name": "Authorization", "header_value": "Bearer ${__FileToString(/opt/jmeter/tokens/cognito_token_latest.token,,)}", "...": "..." }
}
```

有効期限だけを取り出す例:

```bash
jq -r '.validity.expires_at.local' /opt/jmeter/tokens/cognito_token_latest.meta.json
```

### 画面表示の例

```
==============================================================================
 Amazon Cognito M2M アクセストークン取得結果
==============================================================================
[出力ファイル]
  Token File       : /opt/jmeter/tokens/cognito_token_20261020_071722.token
  Metadata File    : /opt/jmeter/tokens/cognito_token_20261020_071722.meta.json
  Latest Token     : /opt/jmeter/tokens/cognito_token_latest.token -> cognito_token_20261020_071722.token
  Latest Metadata  : /opt/jmeter/tokens/cognito_token_latest.meta.json -> cognito_token_20261020_071722.meta.json
  Token Format     : raw
  Token SHA-256    : 60caa67fac81bec1a6dbea1208fc656000738e992840ad7decc841ac1b6cd483
  Access Token     : eyJraWQiOiJ4eXo...bmF0dXJl (1043 文字)

[リクエスト]
  ...

[有効期限]
  Acquired At      : 2026-10-20 07:17:22 JST
  Issued At (iat)  : 2026-10-20 07:17:22 JST  [epoch: 1792448242]
  Expires At (exp) : 2026-10-20 08:17:22 JST  [epoch: 1792451842]
  expires_in       : 3600 秒
  Lifetime         : 3600 秒 (1h 00m 00s)
  Remaining        : 3599 秒 (0h 59m 59s)

[JWT クレーム概要]
  iss / client_id / sub / token_use / scope / jti / version / auth_time / kid / alg

[JWT Header (デコード結果)]
[JWT Payload (デコード結果)]
  (デコードした JSON 全体)

[JMeter 設定例]
  Header Name      : Authorization
  Header Value     : Bearer ${__FileToString(/opt/jmeter/tokens/cognito_token_latest.token,,)}
==============================================================================
```

日時はサーバのタイムゾーンで表示します。変更する場合は `TZ=Asia/Tokyo ./get_cognito_token.sh ...` のように実行してください。

## JMeter での設定

### raw 形式 (推奨)

HTTP ヘッダマネージャに以下を設定します。

| 名前 | 値 |
| --- | --- |
| `Authorization` | `Bearer ${__FileToString(/opt/jmeter/tokens/cognito_token_latest.token,,)}` |

`__FileToString` はサンプラー実行のたびにファイルを読み込むため、テスト実行中にトークンを再取得しても新しいトークンが自動的に使われます。

### properties 形式

```bash
./get_cognito_token.sh ... -f properties -o /opt/jmeter/tokens
jmeter -n -t test.jmx -q /opt/jmeter/tokens/cognito_token_latest.properties
```

| 名前 | 値 |
| --- | --- |
| `Authorization` | `${__P(authorization)}` |

プロパティは JMeter 起動時に 1 回だけ読み込まれます。

### csv 形式

CSV Data Set Config の「ファイル名」に `/opt/jmeter/tokens/cognito_token_latest.csv` を指定し、「変数名」は空欄 (1 行目のヘッダを使用) にします。

| 名前 | 値 |
| --- | --- |
| `Authorization` | `${authorization}` |

## 長時間テストでのトークン更新

Cognito のアクセストークンの有効期間は既定で 60 分です。これより長いテストでは、raw 形式で出力し cron などで有効期限より前に再取得してください。
`*_latest.token` のリンクは原子的に張り替えるため、実行中の JMeter にそのまま反映されます。

```cron
# 30 分ごと (毎時 0 分と 30 分) に再取得し、直近 3 世代だけ残す
*/30 * * * * /opt/tools/get_cognito_token.sh -q --keep 3 -c 1example23456789abcdefghij --client-secret-file /opt/tools/.client_secret -u https://example.auth.ap-northeast-1.amazoncognito.com/oauth2/token -S "my-api/read" -o /opt/jmeter/tokens >>/var/log/cognito_token.log 2>&1
```

## 終了コード

| コード | 意味 |
| :---: | --- |
| 0 | 正常終了 |
| 1 | パラメータ不正 |
| 2 | 必要なコマンドが無い |
| 3 | 通信エラー / HTTP エラー (認証失敗、スコープ不正など) |
| 4 | レスポンス / トークンの解析エラー |
| 5 | ファイル出力エラー |

## トラブルシューティング

| エラー | 主な原因 |
| --- | --- |
| `invalid_client` | クライアント ID / シークレットの誤り、またはシークレットなしのアプリクライアント |
| `invalid_scope` | スコープ文字列の誤り (`<リソースサーバー識別子>/<スコープ名>` 形式)、またはクライアントに未許可のスコープ |
| `unauthorized_client` | アプリクライアントで client_credentials フローが有効になっていない |
| `unsupported_grant_type` | グラントタイプの誤り (`client_credentials` を指定) |
| HTTP 404 / 405 | トークンエンドポイント URL (ドメイン名、`/oauth2/token` パス) の誤り |
| curl の通信エラー | ネットワーク / プロキシ設定。プロキシ環境では `https_proxy` 環境変数を設定してください |
| 時刻ずれの警告 | サーバの時刻が大きくずれています。`chronyd` の設定を確認してください |

## 注意事項

- 本スクリプトは JWT の**デコードのみ**を行い、署名検証は行いません (メタデータの `jwt.signature_verified` は常に `false`)。
- トークンファイルは認証情報そのものです。出力先ディレクトリをバージョン管理やファイル共有の対象に含めないでください。

## テスト

模擬トークンエンドポイントを起動して主要な動作 (各出力形式、認証方式、世代管理、エラー処理など) を確認します。

```bash
tests/run_tests.sh
```
