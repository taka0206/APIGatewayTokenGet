#!/usr/bin/env bash
#
# get_cognito_token.sh
#
#   Amazon Cognito ユーザープールのトークンエンドポイントから M2M 認証
#   (OAuth 2.0 client_credentials グラント) 用のアクセストークンを取得し、
#   Apache JMeter の HTTP ヘッダマネージャで利用しやすい形式でファイルに出力する。
#   併せてアクセストークン (JWT) をデコードし、有効期限などのメタデータを
#   画面に表示するとともに、トークンファイルと同じベース名のメタデータファイル
#   (<ベース名>.meta.json) に出力する。
#
#   動作環境: RHEL 9.x (bash 5.1 以上 / coreutils / curl / jq 1.6 以上)
#
#   詳細は ./get_cognito_token.sh --help または README.md を参照。
#
set -euo pipefail
umask 077

readonly SCRIPT_NAME=${0##*/}
readonly SCRIPT_VERSION="1.0.0"

# 終了コード
readonly EXIT_USAGE=1
readonly EXIT_DEPENDENCY=2
readonly EXIT_HTTP=3
readonly EXIT_TOKEN=4
readonly EXIT_OUTPUT=5

# 取得したトークンの残り有効期間がこの秒数未満なら警告する
readonly WARN_REMAINING_SECONDS=300
# トークンの iat とローカル時刻の差がこの秒数を超えたら時刻ずれを警告する
readonly WARN_CLOCK_SKEW_SECONDS=300

# ---------------------------------------------------------------------------
# パラメータ (環境変数で既定値を与えられるものは環境変数を初期値とする)
# ---------------------------------------------------------------------------
CLIENT_ID=${COGNITO_CLIENT_ID:-}
CLIENT_SECRET=${COGNITO_CLIENT_SECRET:-}
CLIENT_SECRET_ARG=""
CLIENT_SECRET_FILE=""
TOKEN_URL=${COGNITO_TOKEN_URL:-}
GRANT_TYPE=${COGNITO_GRANT_TYPE:-client_credentials}
SCOPE=${COGNITO_SCOPE:-}
OUTPUT_DIR=${TOKEN_OUTPUT_DIR:-}
NAME="cognito_token"
FORMAT="raw"
AUTH_METHOD="basic"
USE_TIMESTAMP=true
KEEP=0
CACERT=""
CONNECT_TIMEOUT=10
MAX_TIME=30
RETRY=0
SHOW_TOKEN=false
QUIET=false

# ---------------------------------------------------------------------------
# 実行時に設定される値
# ---------------------------------------------------------------------------
WORK_DIR=""
TMP_FILES=()
RESPONSE_FILE=""
CURL_ERR_FILE=""
ACQUIRED_AT=""
ACCESS_TOKEN=""
TOKEN_TYPE=""
EXPIRES_IN=""
TOKEN_SHA256=""
JWT_HEADER_JSON=""
JWT_PAYLOAD_JSON=""
JWT_IAT=""
JWT_EXP=""
JWT_AUTH_TIME=""
TOKEN_EXT=""
TOKEN_BASENAME=""
TOKEN_PATH=""
META_BASENAME=""
META_PATH=""
LATEST_TOKEN_PATH=""
LATEST_META_PATH=""
STABLE_TOKEN_PATH=""
JMETER_SETUP=""
JMETER_HEADER_VALUE=""

# ---------------------------------------------------------------------------
# 共通関数
# ---------------------------------------------------------------------------
log_info() {
  if [[ $QUIET != true ]]; then
    printf '[INFO]  %s\n' "$*" >&2
  fi
}

log_warn() {
  printf '[WARN]  %s\n' "$*" >&2
}

log_error() {
  printf '[ERROR] %s\n' "$*" >&2
}

die() {
  local rc=$1
  shift
  log_error "$@"
  exit "$rc"
}

cleanup() {
  local f
  for f in "${TMP_FILES[@]}"; do
    if [[ -e $f || -L $f ]]; then
      rm -f -- "$f"
    fi
  done
  if [[ -n $WORK_DIR && -d $WORK_DIR ]]; then
    rm -rf -- "$WORK_DIR"
  fi
  return 0
}

usage() {
  cat <<EOF
使い方:
  ${SCRIPT_NAME} -c <CLIENT_ID> -s <CLIENT_SECRET> -u <TOKEN_URL> -o <OUTPUT_DIR> [オプション]

概要:
  Amazon Cognito ユーザープールのトークンエンドポイントから M2M 認証
  (OAuth 2.0 client_credentials グラント) のアクセストークンを取得し、
  JMeter の HTTP ヘッダマネージャで利用しやすい形式で出力ディレクトリに保存します。
  アクセストークン (JWT) をデコードした有効期限などのメタデータは画面に表示し、
  トークンファイルと同じベース名のメタデータファイル (<ベース名>.meta.json) に出力します。

必須パラメータ:
  -c, --client-id ID             アプリクライアント ID                  [env: COGNITO_CLIENT_ID]
  -s, --client-secret SECRET     クライアントシークレット                [env: COGNITO_CLIENT_SECRET]
      --client-secret-file FILE  クライアントシークレットをファイルの 1 行目から読み込む
                                 (いずれも指定が無く端末から実行した場合は対話入力)
  -u, --token-url URL            トークンエンドポイント URL              [env: COGNITO_TOKEN_URL]
                                 例) https://<domain>.auth.<region>.amazoncognito.com/oauth2/token
                                 (パスを省略した場合は /oauth2/token を補完)
  -o, --output-dir DIR           出力先ディレクトリ (存在しない場合は作成) [env: TOKEN_OUTPUT_DIR]

任意パラメータ:
  -g, --grant-type TYPE          グラントタイプ (既定: client_credentials)  [env: COGNITO_GRANT_TYPE]
                                 clientcredentials / client-credentials も client_credentials として扱う
  -S, --scope SCOPE              カスタムスコープ (例: "my-api/read my-api/write") [env: COGNITO_SCOPE]
                                 スペース区切りで複数指定可。オプション自体の複数回指定も可。
                                 省略時はアプリクライアントに許可された全スコープが付与される
  -n, --name NAME                出力ファイル名のプレフィックス (既定: cognito_token)
                                 使用可能文字: 英数字 . _ -
  -f, --format FORMAT            トークンファイルの形式 (既定: raw)
                                   raw        : トークン文字列のみ (末尾改行なし) -> <ベース名>.token
                                   properties : JMeter プロパティファイル (-q 用)  -> <ベース名>.properties
                                   csv        : CSV Data Set Config 用            -> <ベース名>.csv
  -a, --auth-method METHOD       クライアント認証方式 (既定: basic)
                                   basic : Authorization: Basic ヘッダで送信 (client_secret_basic)
                                   post  : リクエストボディで送信           (client_secret_post)
      --no-timestamp             タイムスタンプなしの固定ファイル名 (<NAME>.<拡張子>) で上書き出力する
      --keep N                   タイムスタンプ付きファイルを新しい順に N 世代だけ残す (既定: 0 = 削除しない)
      --cacert FILE              サーバ証明書の検証に使用する CA 証明書バンドル
      --connect-timeout SEC      接続タイムアウト秒数 (既定: 10)
      --max-time SEC             リクエスト全体のタイムアウト秒数 (既定: 30)
      --retry N                  一時的なエラー時のリトライ回数 (既定: 0)
      --show-token               アクセストークン全文を画面に表示する (既定: 先頭と末尾のみ表示)
  -q, --quiet                    画面表示を抑止し、トークンファイルのパスのみを標準出力に出力する
  -h, --help                     このヘルプを表示する
  -V, --version                  バージョンを表示する

出力ファイル (既定: タイムスタンプ付き。<拡張子> は --format により token / properties / csv):
  <OUTPUT_DIR>/<NAME>_<YYYYmmdd_HHMMSS>.<拡張子>   アクセストークン
  <OUTPUT_DIR>/<NAME>_<YYYYmmdd_HHMMSS>.meta.json  メタデータ (トークンファイルと同じベース名)
  <OUTPUT_DIR>/<NAME>_latest.<拡張子>              最新のトークンファイルへのシンボリックリンク
  <OUTPUT_DIR>/<NAME>_latest.meta.json             最新のメタデータファイルへのシンボリックリンク

JMeter での利用例 (HTTP ヘッダマネージャ):
  raw        : 名前 = Authorization
               値   = Bearer \${__FileToString(<OUTPUT_DIR>/<NAME>_latest.token,,)}
  properties : jmeter -n -t test.jmx -q <OUTPUT_DIR>/<NAME>_latest.properties で起動し
               名前 = Authorization / 値 = \${__P(authorization)}
  csv        : CSV Data Set Config のファイル名に <OUTPUT_DIR>/<NAME>_latest.csv を指定し
               名前 = Authorization / 値 = \${authorization}

終了コード:
  0: 正常終了            1: パラメータ不正          2: 必要なコマンドが無い
  3: 通信 / HTTP エラー  4: レスポンス / トークン解析エラー  5: ファイル出力エラー

実行例:
  ${SCRIPT_NAME} \\
    -c 1example23456789abcdefghij \\
    --client-secret-file ~/.cognito/client_secret \\
    -u https://example.auth.ap-northeast-1.amazoncognito.com/oauth2/token \\
    -g client_credentials \\
    -S "my-api/read my-api/write" \\
    -o /opt/jmeter/tokens
EOF
}

# オプションに値が指定されているか確認する
require_value() {
  if (($# < 2)); then
    die "$EXIT_USAGE" "オプション $1 には値が必要です (--help で使い方を表示)"
  fi
}

require_integer() {
  local opt=$1 value=$2
  if [[ ! $value =~ ^[0-9]+$ ]]; then
    die "$EXIT_USAGE" "オプション ${opt} には 0 以上の整数を指定してください: ${value}"
  fi
}

# Base64URL (パディング無し) をデコードする
b64url_decode() {
  local data=${1//-/+}
  data=${data//_//}
  case $((${#data} % 4)) in
    0) ;;
    2) data+="==" ;;
    3) data+="=" ;;
    *) return 1 ;;
  esac
  printf '%s' "$data" | base64 -d 2>/dev/null
}

# curl 設定ファイル用にダブルクォートで囲んだ文字列を出力する
cfg_quote() {
  local s=${1//\\/\\\\}
  s=${s//\"/\\\"}
  printf '"%s"' "$s"
}

fmt_local() { date -d "@$1" '+%Y-%m-%d %H:%M:%S %Z'; }
iso_local() { date -d "@$1" '+%Y-%m-%dT%H:%M:%S%:z'; }
iso_utc() { date -u -d "@$1" '+%Y-%m-%dT%H:%M:%SZ'; }

# 秒数を "1h 02m 03s" 形式で出力する
fmt_duration() {
  local s=$1 sign=""
  if ((s < 0)); then
    sign="-"
    s=$((-s))
  fi
  printf '%s%dh %02dm %02ds' "$sign" $((s / 3600)) $((s % 3600 / 60)) $((s % 60))
}

# エポック秒を {"epoch":..,"local":..,"utc":..} 形式の JSON で出力する
time_json() {
  jq -n --argjson epoch "$1" --arg local "$(iso_local "$1")" --arg utc "$(iso_utc "$1")" \
    '{epoch: $epoch, local: $local, utc: $utc}'
}

# JSON 文字列から指定キーの値を取り出す (無い場合は "-")
json_value() {
  jq -r --arg key "$2" '.[$key] // "-" | if type == "string" then . else tojson end' <<<"$1"
}

# ---------------------------------------------------------------------------
# 引数解析・検証
# ---------------------------------------------------------------------------
parse_args() {
  local scope_from_cli=false

  while (($# > 0)); do
    # --option=value 形式を --option value 形式に分解する
    if [[ $1 == --*=* ]]; then
      set -- "${1%%=*}" "${1#*=}" "${@:2}"
    fi

    case $1 in
      -c | --client-id)
        require_value "$@"
        CLIENT_ID=$2
        shift 2
        ;;
      -s | --client-secret)
        require_value "$@"
        CLIENT_SECRET_ARG=$2
        shift 2
        ;;
      --client-secret-file)
        require_value "$@"
        CLIENT_SECRET_FILE=$2
        shift 2
        ;;
      -u | --token-url)
        require_value "$@"
        TOKEN_URL=$2
        shift 2
        ;;
      -g | --grant-type)
        require_value "$@"
        GRANT_TYPE=$2
        shift 2
        ;;
      -S | --scope)
        require_value "$@"
        if [[ $scope_from_cli == true ]]; then
          SCOPE+=" $2"
        else
          SCOPE=$2
          scope_from_cli=true
        fi
        shift 2
        ;;
      -o | --output-dir)
        require_value "$@"
        OUTPUT_DIR=$2
        shift 2
        ;;
      -n | --name)
        require_value "$@"
        NAME=$2
        shift 2
        ;;
      -f | --format)
        require_value "$@"
        FORMAT=$2
        shift 2
        ;;
      -a | --auth-method)
        require_value "$@"
        AUTH_METHOD=$2
        shift 2
        ;;
      --no-timestamp)
        USE_TIMESTAMP=false
        shift
        ;;
      --keep)
        require_value "$@"
        KEEP=$2
        shift 2
        ;;
      --cacert)
        require_value "$@"
        CACERT=$2
        shift 2
        ;;
      --connect-timeout)
        require_value "$@"
        CONNECT_TIMEOUT=$2
        shift 2
        ;;
      --max-time)
        require_value "$@"
        MAX_TIME=$2
        shift 2
        ;;
      --retry)
        require_value "$@"
        RETRY=$2
        shift 2
        ;;
      --show-token)
        SHOW_TOKEN=true
        shift
        ;;
      -q | --quiet)
        QUIET=true
        shift
        ;;
      -h | --help)
        usage
        exit 0
        ;;
      -V | --version)
        printf '%s %s\n' "$SCRIPT_NAME" "$SCRIPT_VERSION"
        exit 0
        ;;
      *)
        die "$EXIT_USAGE" "不明な引数です: $1 (--help で使い方を表示)"
        ;;
    esac
  done
}

check_dependencies() {
  local cmd missing=()
  for cmd in curl jq base64 date sha256sum mktemp; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      missing+=("$cmd")
    fi
  done
  if ((${#missing[@]} > 0)); then
    log_error "必要なコマンドが見つかりません: ${missing[*]}"
    log_error "RHEL 9 の場合は次のコマンドでインストールしてください: sudo dnf install -y curl jq coreutils"
    exit "$EXIT_DEPENDENCY"
  fi
}

# クライアントシークレットを 引数 > ファイル > 環境変数 > 対話入力 の優先順で決定する
resolve_client_secret() {
  if [[ -n $CLIENT_SECRET_ARG && -n $CLIENT_SECRET_FILE ]]; then
    die "$EXIT_USAGE" "--client-secret と --client-secret-file は同時に指定できません"
  fi

  if [[ -n $CLIENT_SECRET_ARG ]]; then
    CLIENT_SECRET=$CLIENT_SECRET_ARG
  elif [[ -n $CLIENT_SECRET_FILE ]]; then
    if [[ ! -f $CLIENT_SECRET_FILE || ! -r $CLIENT_SECRET_FILE ]]; then
      die "$EXIT_USAGE" "クライアントシークレットファイルを読み込めません: $CLIENT_SECRET_FILE"
    fi
    CLIENT_SECRET=""
    IFS= read -r CLIENT_SECRET <"$CLIENT_SECRET_FILE" || true
  elif [[ -z $CLIENT_SECRET && -t 0 ]]; then
    IFS= read -r -s -p "Client Secret: " CLIENT_SECRET || true
    printf '\n' >&2
  fi

  # 前後の空白・CR (Windows 改行) を除去する
  CLIENT_SECRET=${CLIENT_SECRET//$'\r'/}
  CLIENT_SECRET=${CLIENT_SECRET#"${CLIENT_SECRET%%[![:space:]]*}"}
  CLIENT_SECRET=${CLIENT_SECRET%"${CLIENT_SECRET##*[![:space:]]}"}
}

validate_params() {
  local missing=() scopes=()

  resolve_client_secret

  [[ -n $CLIENT_ID ]] || missing+=("-c/--client-id")
  [[ -n $CLIENT_SECRET ]] || missing+=("-s/--client-secret")
  [[ -n $TOKEN_URL ]] || missing+=("-u/--token-url")
  [[ -n $OUTPUT_DIR ]] || missing+=("-o/--output-dir")
  if ((${#missing[@]} > 0)); then
    die "$EXIT_USAGE" "必須パラメータが指定されていません: ${missing[*]} (--help で使い方を表示)"
  fi

  # トークンエンドポイント URL
  if [[ ! $TOKEN_URL =~ ^https?://[^/[:space:]]+(/[^[:space:]]*)?$ ]]; then
    die "$EXIT_USAGE" "トークンエンドポイント URL が不正です: $TOKEN_URL"
  fi
  if [[ $TOKEN_URL =~ ^https?://[^/]+/?$ ]]; then
    TOKEN_URL="${TOKEN_URL%/}/oauth2/token"
    log_info "URL にパスが無いため /oauth2/token を補完しました: $TOKEN_URL"
  fi
  if [[ $TOKEN_URL == http://* ]]; then
    log_warn "暗号化されない http:// の URL が指定されています。通常は https:// を使用してください"
  fi

  # グラントタイプ (表記ゆれを client_credentials に正規化する)
  GRANT_TYPE=${GRANT_TYPE,,}
  case $GRANT_TYPE in
    client_credentials | clientcredentials | client-credentials)
      GRANT_TYPE="client_credentials"
      ;;
    "")
      die "$EXIT_USAGE" "グラントタイプが空です"
      ;;
    *)
      log_warn "Cognito の M2M 認証で使用するグラントタイプは client_credentials です (指定値: $GRANT_TYPE)"
      ;;
  esac

  # スコープ (連続する空白を 1 つにまとめる)
  read -r -a scopes <<<"$SCOPE" || true
  SCOPE="${scopes[*]}"

  # 出力ファイル名プレフィックス
  if [[ ! $NAME =~ ^[A-Za-z0-9._-]+$ ]]; then
    die "$EXIT_USAGE" "--name に使用できる文字は英数字と . _ - のみです: $NAME"
  fi

  case $FORMAT in
    raw) TOKEN_EXT="token" ;;
    properties) TOKEN_EXT="properties" ;;
    csv) TOKEN_EXT="csv" ;;
    *) die "$EXIT_USAGE" "--format には raw / properties / csv のいずれかを指定してください: $FORMAT" ;;
  esac

  case $AUTH_METHOD in
    basic | post) ;;
    *) die "$EXIT_USAGE" "--auth-method には basic / post のいずれかを指定してください: $AUTH_METHOD" ;;
  esac

  require_integer --keep "$KEEP"
  require_integer --connect-timeout "$CONNECT_TIMEOUT"
  require_integer --max-time "$MAX_TIME"
  require_integer --retry "$RETRY"

  if [[ -n $CACERT && ! -r $CACERT ]]; then
    die "$EXIT_USAGE" "CA 証明書ファイルを読み込めません: $CACERT"
  fi
}

prepare_output_dir() {
  if [[ ! -d $OUTPUT_DIR ]]; then
    # umask 077 により作成されるディレクトリのパーミッションは 700 となる
    if ! mkdir -p -- "$OUTPUT_DIR"; then
      die "$EXIT_OUTPUT" "出力先ディレクトリを作成できません: $OUTPUT_DIR"
    fi
    log_info "出力先ディレクトリを作成しました: $OUTPUT_DIR"
  fi
  # JMeter から参照しやすいよう絶対パスに変換する
  OUTPUT_DIR=$(cd -- "$OUTPUT_DIR" && pwd -P) ||
    die "$EXIT_OUTPUT" "出力先ディレクトリにアクセスできません: $OUTPUT_DIR"
  if [[ ! -w $OUTPUT_DIR ]]; then
    die "$EXIT_OUTPUT" "出力先ディレクトリに書き込み権限がありません: $OUTPUT_DIR"
  fi
}

# ---------------------------------------------------------------------------
# トークン取得
# ---------------------------------------------------------------------------

# curl の設定を標準出力に出力する。
# シークレットがプロセス一覧 (ps) に表示されないよう、コマンドライン引数ではなく
# 標準入力経由の設定ファイル (--config -) として curl に渡す。
build_curl_config() {
  printf 'url = %s\n' "$(cfg_quote "$TOKEN_URL")"
  printf 'header = %s\n' "$(cfg_quote "Content-Type: application/x-www-form-urlencoded")"
  printf 'header = %s\n' "$(cfg_quote "Accept: application/json")"
  printf 'data-urlencode = %s\n' "$(cfg_quote "grant_type=${GRANT_TYPE}")"
  if [[ -n $SCOPE ]]; then
    printf 'data-urlencode = %s\n' "$(cfg_quote "scope=${SCOPE}")"
  fi
  if [[ $AUTH_METHOD == basic ]]; then
    printf 'header = %s\n' \
      "$(cfg_quote "Authorization: Basic $(printf '%s:%s' "$CLIENT_ID" "$CLIENT_SECRET" | base64 -w 0)")"
  else
    printf 'data-urlencode = %s\n' "$(cfg_quote "client_id=${CLIENT_ID}")"
    printf 'data-urlencode = %s\n' "$(cfg_quote "client_secret=${CLIENT_SECRET}")"
  fi
}

# エラーレスポンスの内容と対処のヒントを表示する
report_error_response() {
  local http_code=$1 error="" description="" hint=""

  if jq -e 'type == "object"' "$RESPONSE_FILE" >/dev/null 2>&1; then
    error=$(jq -r '.error // empty | tostring' "$RESPONSE_FILE")
    description=$(jq -r '(.error_description // .message // empty) | tostring' "$RESPONSE_FILE")
  fi

  log_error "アクセストークンの取得に失敗しました (HTTP ステータス: ${http_code})"
  if [[ -n $error ]]; then
    log_error "  error             : $error"
  fi
  if [[ -n $description ]]; then
    log_error "  error_description : $description"
  fi
  if [[ -z $error && -z $description && -s $RESPONSE_FILE ]]; then
    log_error "  response          : $(head -c 500 "$RESPONSE_FILE" | tr '\r\n' '  ')"
  fi

  case $error in
    invalid_client)
      hint="クライアント ID / クライアントシークレットが誤っているか、シークレットを持たないアプリクライアントです"
      ;;
    invalid_scope)
      hint="スコープが誤っているか、アプリクライアントに許可されていません (形式: <リソースサーバー識別子>/<スコープ名>)"
      ;;
    unauthorized_client)
      hint="アプリクライアントで client_credentials フロー (クライアント認証情報) が許可されていません"
      ;;
    unsupported_grant_type | invalid_grant)
      hint="グラントタイプを確認してください (M2M 認証は client_credentials)"
      ;;
    invalid_request)
      hint="必須パラメータの不足、またはリクエスト形式が不正です"
      ;;
    *)
      case $http_code in
        401 | 403) hint="認証情報、またはネットワーク / プロキシ設定を確認してください" ;;
        404 | 405) hint="トークンエンドポイント URL (ドメイン名と /oauth2/token パス) を確認してください" ;;
        429) hint="リクエストが制限されました。時間を置いて再実行してください" ;;
        5??) hint="Cognito 側の一時的なエラーの可能性があります。--retry の指定を検討してください" ;;
      esac
      ;;
  esac
  if [[ -n $hint ]]; then
    log_error "  hint              : $hint"
  fi
}

request_token() {
  local http_code rc=0
  local -a curl_opts=(
    --config -
    --silent
    --show-error
    --output "$RESPONSE_FILE"
    --write-out '%{http_code}'
    --connect-timeout "$CONNECT_TIMEOUT"
    --max-time "$MAX_TIME"
    --retry "$RETRY"
  )
  if [[ -n $CACERT ]]; then
    curl_opts+=(--cacert "$CACERT")
  fi

  log_info "アクセストークンを取得します: $TOKEN_URL (grant_type=${GRANT_TYPE}, scope=${SCOPE:-<指定なし>})"
  http_code=$(build_curl_config | curl "${curl_opts[@]}" 2>"$CURL_ERR_FILE") || rc=$?
  ACQUIRED_AT=$(date +%s)

  if ((rc != 0)); then
    log_error "トークンエンドポイントへの通信に失敗しました (curl 終了コード: ${rc})"
    if [[ -s $CURL_ERR_FILE ]]; then
      sed 's/^/        /' "$CURL_ERR_FILE" >&2
    fi
    exit "$EXIT_HTTP"
  fi
  if [[ $http_code != 200 ]]; then
    report_error_response "$http_code"
    exit "$EXIT_HTTP"
  fi
}

parse_response() {
  if ! jq -e 'type == "object"' "$RESPONSE_FILE" >/dev/null 2>&1; then
    die "$EXIT_TOKEN" "トークンエンドポイントのレスポンスが JSON オブジェクトではありません"
  fi

  ACCESS_TOKEN=$(jq -r '.access_token // empty | strings' "$RESPONSE_FILE")
  TOKEN_TYPE=$(jq -r '.token_type // "Bearer" | tostring' "$RESPONSE_FILE")
  EXPIRES_IN=$(jq -r '.expires_in // empty | tostring' "$RESPONSE_FILE")

  if [[ -z $ACCESS_TOKEN ]]; then
    die "$EXIT_TOKEN" "レスポンスに access_token が含まれていません"
  fi
  if [[ ! $EXPIRES_IN =~ ^[0-9]+$ ]]; then
    EXPIRES_IN=""
  fi
  TOKEN_SHA256=$(printf '%s' "$ACCESS_TOKEN" | sha256sum | cut -d ' ' -f 1)
}

# アクセストークン (JWT) のヘッダとペイロードをデコードする (署名検証は行わない)
decode_jwt() {
  local header_part payload_part

  if [[ ! $ACCESS_TOKEN =~ ^([A-Za-z0-9_-]+)\.([A-Za-z0-9_-]+)\.([A-Za-z0-9_-]*)$ ]]; then
    die "$EXIT_TOKEN" "アクセストークンが JWT 形式 (header.payload.signature) ではありません"
  fi
  header_part=${BASH_REMATCH[1]}
  payload_part=${BASH_REMATCH[2]}

  JWT_HEADER_JSON=$(b64url_decode "$header_part" | jq -ce 'select(type == "object")' 2>/dev/null) ||
    die "$EXIT_TOKEN" "JWT ヘッダをデコードできません"
  JWT_PAYLOAD_JSON=$(b64url_decode "$payload_part" | jq -ce 'select(type == "object")' 2>/dev/null) ||
    die "$EXIT_TOKEN" "JWT ペイロードをデコードできません"

  JWT_IAT=$(jq -r '.iat // empty | numbers | floor' <<<"$JWT_PAYLOAD_JSON")
  JWT_EXP=$(jq -r '.exp // empty | numbers | floor' <<<"$JWT_PAYLOAD_JSON")
  JWT_AUTH_TIME=$(jq -r '.auth_time // empty | numbers | floor' <<<"$JWT_PAYLOAD_JSON")

  if [[ -z $JWT_IAT ]]; then
    log_warn "JWT に iat クレームが無いため、取得日時を発行日時として扱います"
    JWT_IAT=$ACQUIRED_AT
  fi
  if [[ -z $JWT_EXP ]]; then
    if [[ -z $EXPIRES_IN ]]; then
      die "$EXIT_TOKEN" "JWT の exp クレーム、レスポンスの expires_in のいずれも無く有効期限を判定できません"
    fi
    log_warn "JWT に exp クレームが無いため、取得日時 + expires_in を有効期限として扱います"
    JWT_EXP=$((ACQUIRED_AT + EXPIRES_IN))
  fi
}

# Cognito のアクセストークンとして想定どおりの内容か確認する (問題があれば警告のみ)
check_claims() {
  local token_use token_client_id granted requested=() s skew remaining

  token_use=$(jq -r '.token_use // empty | tostring' <<<"$JWT_PAYLOAD_JSON")
  if [[ $token_use != access ]]; then
    log_warn "token_use が access ではありません: ${token_use:-<なし>}"
  fi

  token_client_id=$(jq -r '.client_id // empty | tostring' <<<"$JWT_PAYLOAD_JSON")
  if [[ -n $token_client_id && $token_client_id != "$CLIENT_ID" ]]; then
    log_warn "トークンの client_id (${token_client_id}) が指定したクライアント ID と一致しません"
  fi

  granted=" $(jq -r '.scope // empty | tostring' <<<"$JWT_PAYLOAD_JSON") "
  read -r -a requested <<<"$SCOPE" || true
  for s in "${requested[@]}"; do
    if [[ $granted != *" ${s} "* ]]; then
      log_warn "要求したスコープ ${s} がトークンの scope クレームに含まれていません"
    fi
  done

  skew=$((JWT_IAT - ACQUIRED_AT))
  if ((skew > WARN_CLOCK_SKEW_SECONDS || skew < -WARN_CLOCK_SKEW_SECONDS)); then
    log_warn "トークンの発行日時とローカル時刻に ${skew} 秒のずれがあります。NTP (chronyd) の設定を確認してください"
  fi

  remaining=$((JWT_EXP - ACQUIRED_AT))
  if ((remaining <= 0)); then
    log_warn "取得したトークンは既に有効期限切れです (exp: $(fmt_local "$JWT_EXP"))"
  elif ((remaining < WARN_REMAINING_SECONDS)); then
    log_warn "取得したトークンの残り有効期間が ${remaining} 秒しかありません"
  fi
}

# ---------------------------------------------------------------------------
# ファイル出力
# ---------------------------------------------------------------------------

# 出力ファイル名を決定する。トークンとメタデータは同じベース名 (stem) を共有する。
decide_file_names() {
  local stem ts n=2 ext exists

  if [[ $USE_TIMESTAMP == true ]]; then
    ts=$(date -d "@$ACQUIRED_AT" '+%Y%m%d_%H%M%S')
    stem="${NAME}_${ts}"
    # 同一秒に複数回実行された場合は連番を付与して既存ファイルを上書きしない
    while true; do
      exists=false
      for ext in meta.json token properties csv; do
        if [[ -e $OUTPUT_DIR/$stem.$ext || -L $OUTPUT_DIR/$stem.$ext ]]; then
          exists=true
        fi
      done
      [[ $exists == true ]] || break
      stem="${NAME}_${ts}_${n}"
      n=$((n + 1))
    done
    LATEST_TOKEN_PATH="$OUTPUT_DIR/${NAME}_latest.${TOKEN_EXT}"
    LATEST_META_PATH="$OUTPUT_DIR/${NAME}_latest.meta.json"
  else
    stem=$NAME
  fi

  TOKEN_BASENAME="${stem}.${TOKEN_EXT}"
  META_BASENAME="${stem}.meta.json"
  TOKEN_PATH="$OUTPUT_DIR/$TOKEN_BASENAME"
  META_PATH="$OUTPUT_DIR/$META_BASENAME"
  # JMeter から参照する際に使用する、実行のたびに変わらないパス
  STABLE_TOKEN_PATH=${LATEST_TOKEN_PATH:-$TOKEN_PATH}

  case $FORMAT in
    raw)
      JMETER_SETUP="HTTP ヘッダマネージャに名前 Authorization と下記の値を設定"
      JMETER_HEADER_VALUE="${TOKEN_TYPE} \${__FileToString(${STABLE_TOKEN_PATH},,)}"
      ;;
    properties)
      JMETER_SETUP="jmeter -n -t <test.jmx> -q ${STABLE_TOKEN_PATH} で起動し、HTTP ヘッダマネージャに名前 Authorization と下記の値を設定"
      JMETER_HEADER_VALUE="\${__P(authorization)}"
      ;;
    csv)
      JMETER_SETUP="CSV Data Set Config のファイル名に ${STABLE_TOKEN_PATH} を指定 (変数名は空欄)、HTTP ヘッダマネージャに名前 Authorization と下記の値を設定"
      JMETER_HEADER_VALUE="\${authorization}"
      ;;
  esac
}

render_token_raw() {
  # JMeter の __FileToString で読み込んだ際にヘッダ値へ改行が混入しないよう、末尾改行は付けない
  printf '%s' "$ACCESS_TOKEN"
}

render_token_properties() {
  printf '# Amazon Cognito M2M access token for Apache JMeter\n'
  printf '# usage         : jmeter -n -t <test.jmx> -q %s\n' "$STABLE_TOKEN_PATH"
  printf '# metadata_file : %s\n' "$META_BASENAME"
  printf '# expires_at    : %s\n' "$(iso_local "$JWT_EXP")"
  printf 'access_token=%s\n' "$ACCESS_TOKEN"
  printf 'token_type=%s\n' "$TOKEN_TYPE"
  printf 'authorization=%s %s\n' "$TOKEN_TYPE" "$ACCESS_TOKEN"
  printf 'token_expires_at_epoch=%s\n' "$JWT_EXP"
}

render_token_csv() {
  printf 'access_token,token_type,authorization,expires_at_epoch\n'
  printf '%s,%s,%s %s,%s\n' "$ACCESS_TOKEN" "$TOKEN_TYPE" "$TOKEN_TYPE" "$ACCESS_TOKEN" "$JWT_EXP"
}

render_meta() {
  local auth_time_json=null

  if [[ -n $JWT_AUTH_TIME ]]; then
    auth_time_json=$(time_json "$JWT_AUTH_TIME")
  fi

  jq -n \
    --arg generator "$SCRIPT_NAME $SCRIPT_VERSION" \
    --arg token_file "$TOKEN_BASENAME" \
    --arg token_path "$TOKEN_PATH" \
    --arg format "$FORMAT" \
    --arg meta_file "$META_BASENAME" \
    --arg meta_path "$META_PATH" \
    --arg latest_token "$LATEST_TOKEN_PATH" \
    --arg latest_meta "$LATEST_META_PATH" \
    --arg sha256 "$TOKEN_SHA256" \
    --argjson length "${#ACCESS_TOKEN}" \
    --arg token_url "$TOKEN_URL" \
    --arg grant_type "$GRANT_TYPE" \
    --arg client_id "$CLIENT_ID" \
    --arg auth_method "$AUTH_METHOD" \
    --arg scope "$SCOPE" \
    --arg token_type "$TOKEN_TYPE" \
    --argjson expires_in "${EXPIRES_IN:-null}" \
    --argjson acquired "$(time_json "$ACQUIRED_AT")" \
    --argjson issued "$(time_json "$JWT_IAT")" \
    --argjson expires "$(time_json "$JWT_EXP")" \
    --argjson auth_time "$auth_time_json" \
    --argjson header "$JWT_HEADER_JSON" \
    --argjson payload "$JWT_PAYLOAD_JSON" \
    --arg jmeter_setup "$JMETER_SETUP" \
    --arg jmeter_file "$STABLE_TOKEN_PATH" \
    --arg jmeter_header_value "$JMETER_HEADER_VALUE" \
    '
    def nullable: if . == "" then null else . end;
    {
      meta_version: 1,
      generator: $generator,
      description: "Metadata of the Amazon Cognito M2M access token stored in files.token_file",
      files: {
        token_file: $token_file,
        token_file_path: $token_path,
        token_format: $format,
        metadata_file: $meta_file,
        metadata_file_path: $meta_path,
        latest_token_link: ($latest_token | nullable),
        latest_metadata_link: ($latest_meta | nullable)
      },
      token_fingerprint: {
        sha256: $sha256,
        length: $length,
        jti: ($payload | .jti)
      },
      request: {
        token_url: $token_url,
        grant_type: $grant_type,
        client_id: $client_id,
        client_auth_method: (if $auth_method == "basic" then "client_secret_basic" else "client_secret_post" end),
        requested_scope: ($scope | nullable)
      },
      response: {
        http_status: 200,
        token_type: $token_type,
        expires_in: $expires_in
      },
      acquired_at: $acquired,
      validity: {
        issued_at: $issued,
        expires_at: $expires,
        lifetime_seconds: ($expires.epoch - $issued.epoch),
        remaining_seconds_at_acquisition: ($expires.epoch - $acquired.epoch)
      },
      claims_summary: {
        iss: ($payload | .iss),
        client_id: ($payload | .client_id),
        sub: ($payload | .sub),
        token_use: ($payload | .token_use),
        scope: ($payload | .scope),
        scopes: (($payload | .scope // "") | tostring | split(" ") | map(select(length > 0))),
        jti: ($payload | .jti),
        version: ($payload | .version),
        auth_time: $auth_time,
        kid: ($header | .kid),
        alg: ($header | .alg)
      },
      jwt: {
        signature_verified: false,
        header: $header,
        payload: $payload
      },
      jmeter: {
        setup: $jmeter_setup,
        reference_file: $jmeter_file,
        header_name: "Authorization",
        header_value: $jmeter_header_value
      }
    }'
}

# 一時ファイルに書き出してから mv で置き換える (JMeter が読み込み中でも中途半端な内容を読ませない)
# 引数: $1=出力先パス, $2...=内容を標準出力に出力するコマンド
write_atomic() {
  local dest=$1 tmp
  shift
  tmp=$(mktemp "${dest%/*}/.${dest##*/}.XXXXXX") || return 1
  TMP_FILES+=("$tmp")
  "$@" >"$tmp" || return 1
  chmod 600 "$tmp" || return 1
  mv -f -- "$tmp" "$dest"
}

# シンボリックリンクを原子的に張り替える
# 引数: $1=リンクのパス, $2=リンク先 (同じディレクトリ内のファイル名)
update_link() {
  local link=$1 target=$2 tmp
  tmp="${link%/*}/.${link##*/}.$$.tmp"
  TMP_FILES+=("$tmp")
  ln -sfn -- "$target" "$tmp" || return 1
  mv -f -T -- "$tmp" "$link"
}

write_outputs() {
  write_atomic "$TOKEN_PATH" "render_token_${FORMAT}" ||
    die "$EXIT_OUTPUT" "トークンファイルを出力できません: $TOKEN_PATH"
  write_atomic "$META_PATH" render_meta ||
    die "$EXIT_OUTPUT" "メタデータファイルを出力できません: $META_PATH"

  if [[ $USE_TIMESTAMP == true ]]; then
    update_link "$LATEST_TOKEN_PATH" "$TOKEN_BASENAME" ||
      die "$EXIT_OUTPUT" "シンボリックリンクを作成できません: $LATEST_TOKEN_PATH"
    update_link "$LATEST_META_PATH" "$META_BASENAME" ||
      die "$EXIT_OUTPUT" "シンボリックリンクを作成できません: $LATEST_META_PATH"
  fi
  log_info "トークンファイルを出力しました    : $TOKEN_PATH"
  log_info "メタデータファイルを出力しました  : $META_PATH"
}

# --keep N 指定時、同じ NAME のタイムスタンプ付きファイルを新しい順に N 世代残して削除する
prune_old_generations() {
  local f base rest stem ext path count i
  local -a stems=() sorted=()

  if [[ $USE_TIMESTAMP != true ]] || ((KEEP == 0)); then
    return 0
  fi

  for f in "$OUTPUT_DIR/${NAME}"_*.meta.json; do
    [[ -f $f && ! -L $f ]] || continue
    base=${f##*/}
    rest=${base#"${NAME}"_}
    [[ $rest =~ ^[0-9]{8}_[0-9]{6}(_[0-9]+)?\.meta\.json$ ]] || continue
    stems+=("${f%.meta.json}")
  done
  count=${#stems[@]}
  ((count > KEEP)) || return 0

  # ファイル名のタイムスタンプ順 (ロケールに依存しないバイト順) に並べ替える
  mapfile -d '' -t sorted < <(printf '%s\0' "${stems[@]}" | LC_ALL=C sort -z)

  for ((i = 0; i < count - KEEP; i++)); do
    stem=${sorted[i]}
    # 今回出力したファイルは削除しない (システム時刻が巻き戻った場合の保護)
    [[ $stem != "$OUTPUT_DIR/${META_BASENAME%.meta.json}" ]] || continue
    for ext in meta.json token properties csv; do
      path="$stem.$ext"
      if [[ -f $path && ! -L $path ]]; then
        rm -f -- "$path"
      fi
    done
    log_info "古い世代のファイルを削除しました  : ${stem##*/}.*"
  done
}

# ---------------------------------------------------------------------------
# 画面表示
# ---------------------------------------------------------------------------
print_kv() {
  printf '  %-17s: %s\n' "$1" "$2"
}

print_summary() {
  local line now remaining auth_time
  line=$(printf '%*s' 78 '' | tr ' ' '=')
  now=$(date +%s)
  remaining=$((JWT_EXP - now))

  printf '%s\n' "$line"
  printf ' Amazon Cognito M2M アクセストークン取得結果\n'
  printf '%s\n' "$line"

  printf '[出力ファイル]\n'
  print_kv "Token File" "$TOKEN_PATH"
  print_kv "Metadata File" "$META_PATH"
  if [[ $USE_TIMESTAMP == true ]]; then
    print_kv "Latest Token" "$LATEST_TOKEN_PATH -> $TOKEN_BASENAME"
    print_kv "Latest Metadata" "$LATEST_META_PATH -> $META_BASENAME"
  fi
  print_kv "Token Format" "$FORMAT"
  print_kv "Token SHA-256" "$TOKEN_SHA256"
  if [[ $SHOW_TOKEN == true ]]; then
    print_kv "Access Token" "$ACCESS_TOKEN"
  else
    print_kv "Access Token" "${ACCESS_TOKEN:0:16}...${ACCESS_TOKEN: -8} (${#ACCESS_TOKEN} 文字)"
  fi
  printf '\n'

  printf '[リクエスト]\n'
  print_kv "Token URL" "$TOKEN_URL"
  print_kv "Grant Type" "$GRANT_TYPE"
  print_kv "Client ID" "$CLIENT_ID"
  print_kv "Client Auth" "client_secret_${AUTH_METHOD}"
  print_kv "Requested Scope" "${SCOPE:-<指定なし: クライアントに許可された全スコープ>}"
  printf '\n'

  printf '[有効期限]\n'
  print_kv "Acquired At" "$(fmt_local "$ACQUIRED_AT")"
  print_kv "Issued At (iat)" "$(fmt_local "$JWT_IAT")  [epoch: $JWT_IAT]"
  print_kv "Expires At (exp)" "$(fmt_local "$JWT_EXP")  [epoch: $JWT_EXP]"
  if [[ -n $EXPIRES_IN ]]; then
    print_kv "expires_in" "${EXPIRES_IN} 秒"
  else
    print_kv "expires_in" "-"
  fi
  print_kv "Lifetime" "$((JWT_EXP - JWT_IAT)) 秒 ($(fmt_duration $((JWT_EXP - JWT_IAT))))"
  if ((remaining > 0)); then
    print_kv "Remaining" "${remaining} 秒 ($(fmt_duration "$remaining"))"
  else
    print_kv "Remaining" "有効期限切れ"
  fi
  printf '\n'

  printf '[JWT クレーム概要]\n'
  print_kv "iss" "$(json_value "$JWT_PAYLOAD_JSON" iss)"
  print_kv "client_id" "$(json_value "$JWT_PAYLOAD_JSON" client_id)"
  print_kv "sub" "$(json_value "$JWT_PAYLOAD_JSON" sub)"
  print_kv "token_use" "$(json_value "$JWT_PAYLOAD_JSON" token_use)"
  print_kv "scope" "$(json_value "$JWT_PAYLOAD_JSON" scope)"
  print_kv "jti" "$(json_value "$JWT_PAYLOAD_JSON" jti)"
  print_kv "version" "$(json_value "$JWT_PAYLOAD_JSON" version)"
  if [[ -n $JWT_AUTH_TIME ]]; then
    auth_time="$(fmt_local "$JWT_AUTH_TIME")  [epoch: $JWT_AUTH_TIME]"
  else
    auth_time="-"
  fi
  print_kv "auth_time" "$auth_time"
  print_kv "kid (header)" "$(json_value "$JWT_HEADER_JSON" kid)"
  print_kv "alg (header)" "$(json_value "$JWT_HEADER_JSON" alg)"
  printf '\n'

  printf '[JWT Header (デコード結果)]\n'
  jq . <<<"$JWT_HEADER_JSON" | sed 's/^/  /'
  printf '[JWT Payload (デコード結果)]\n'
  jq . <<<"$JWT_PAYLOAD_JSON" | sed 's/^/  /'
  printf '  ※ JWT の署名検証は行っていません (デコード結果の表示のみ)\n'
  printf '\n'

  printf '[JMeter 設定例]\n'
  printf '  %s\n' "$JMETER_SETUP"
  print_kv "Header Name" "Authorization"
  print_kv "Header Value" "$JMETER_HEADER_VALUE"
  printf '%s\n' "$line"
}

# ---------------------------------------------------------------------------
# メイン処理
# ---------------------------------------------------------------------------
main() {
  parse_args "$@"
  check_dependencies
  validate_params
  prepare_output_dir

  trap cleanup EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  WORK_DIR=$(mktemp -d) || die "$EXIT_OUTPUT" "一時ディレクトリを作成できません"
  RESPONSE_FILE="$WORK_DIR/response.json"
  CURL_ERR_FILE="$WORK_DIR/curl.err"

  request_token
  parse_response
  decode_jwt
  check_claims

  decide_file_names
  write_outputs
  prune_old_generations

  if [[ $QUIET == true ]]; then
    printf '%s\n' "$TOKEN_PATH"
  else
    print_summary
  fi
}

main "$@"
