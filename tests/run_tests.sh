#!/usr/bin/env bash
#
# get_cognito_token.sh のテスト
#   模擬トークンエンドポイント (mock_cognito_server.py) を起動し、主要な動作を確認する。
#   必要なもの: bash / curl / jq / python3
#
#   実行: tests/run_tests.sh
#
# 単一引用符内の $ は意図的に展開させない (bash -c の引数参照や JMeter の関数書式のため)
# shellcheck disable=SC2016
set -uo pipefail

TEST_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
SCRIPT="$TEST_DIR/../get_cognito_token.sh"
CLIENT_ID="testclientid0123456789abcd"
CLIENT_SECRET="testclientsecret0123456789abcdefghijklmnopqrstuvwxy"

# 実行環境の設定がテストに影響しないようにする
unset COGNITO_CLIENT_ID COGNITO_CLIENT_SECRET COGNITO_TOKEN_URL COGNITO_GRANT_TYPE COGNITO_SCOPE TOKEN_OUTPUT_DIR
export NO_PROXY="127.0.0.1,localhost" no_proxy="127.0.0.1,localhost"

WORK=$(mktemp -d)
SERVER_PID=""
PASS=0
FAIL=0

cleanup() {
  if [[ -n $SERVER_PID ]]; then
    kill "$SERVER_PID" 2>/dev/null
    wait "$SERVER_PID" 2>/dev/null
  fi
  rm -rf -- "$WORK"
}
trap cleanup EXIT

ok() {
  PASS=$((PASS + 1))
  printf '  [PASS] %s\n' "$1"
}

ng() {
  FAIL=$((FAIL + 1))
  printf '  [FAIL] %s\n' "$1"
}

check() {
  local desc=$1
  shift
  if "$@"; then ok "$desc"; else ng "$desc"; fi
}

check_eq() {
  local desc=$1 expected=$2 actual=$3
  if [[ $expected == "$actual" ]]; then
    ok "$desc"
  else
    ng "$desc (expected: '$expected', actual: '$actual')"
  fi
}

# 標準出力・標準エラー・終了コードを保存してスクリプトを実行する
run() {
  "$SCRIPT" "$@" >"$WORK/stdout" 2>"$WORK/stderr"
  RC=$?
}

python3 "$TEST_DIR/mock_cognito_server.py" "$WORK/port" &
SERVER_PID=$!
for _ in $(seq 50); do
  [[ -s $WORK/port ]] && break
  sleep 0.1
done
if [[ ! -s $WORK/port ]]; then
  echo "模擬サーバを起動できませんでした" >&2
  exit 1
fi
PORT=$(cat "$WORK/port")
URL="http://127.0.0.1:${PORT}/oauth2/token"
COMMON=(-c "$CLIENT_ID" -s "$CLIENT_SECRET" -u "$URL")

echo "== raw 形式 (既定) / Basic 認証 / スコープ指定"
OUT="$WORK/raw"
run "${COMMON[@]}" -S "my-api/read" -o "$OUT"
check_eq "終了コード 0" 0 "$RC"
mapfile -t tokens < <(find "$OUT" -maxdepth 1 -type f -name 'cognito_token_*.token')
check_eq "タイムスタンプ付きトークンファイルが 1 つ" 1 "${#tokens[@]}"
TOKEN_FILE=${tokens[0]:-}
META_FILE=${TOKEN_FILE%.token}.meta.json
check "メタデータファイルがトークンファイルと同じベース名" test -f "$META_FILE"
check "トークンファイル末尾に改行が無い" test "$(tail -c 1 "$TOKEN_FILE" | od -An -c | tr -d ' ')" != '\n'
check_eq "トークンファイルのパーミッション 600" 600 "$(stat -c %a "$TOKEN_FILE")"
check_eq "メタデータファイルのパーミッション 600" 600 "$(stat -c %a "$META_FILE")"
check_eq "latest リンク (トークン)" "${TOKEN_FILE##*/}" "$(readlink "$OUT/cognito_token_latest.token")"
check_eq "latest リンク (メタデータ)" "${META_FILE##*/}" "$(readlink "$OUT/cognito_token_latest.meta.json")"
check_eq "メタデータ files.token_file" "${TOKEN_FILE##*/}" "$(jq -r .files.token_file "$META_FILE")"
check_eq "メタデータ token_fingerprint.sha256" "$(sha256sum <"$TOKEN_FILE" | cut -d ' ' -f 1)" \
  "$(jq -r .token_fingerprint.sha256 "$META_FILE")"
check_eq "メタデータ validity.lifetime_seconds" 3600 "$(jq -r .validity.lifetime_seconds "$META_FILE")"
check_eq "メタデータ claims_summary.scope" "my-api/read" "$(jq -r .claims_summary.scope "$META_FILE")"
check_eq "メタデータ request.client_auth_method" "client_secret_basic" "$(jq -r .request.client_auth_method "$META_FILE")"
check "メタデータにシークレットが含まれない" bash -c '! grep -qF "$1" "$2"' _ "$CLIENT_SECRET" "$META_FILE"
check "メタデータにトークン本体が含まれない" bash -c '! grep -qF "$(cat "$1")" "$2"' _ "$TOKEN_FILE" "$META_FILE"
check_eq "メタデータの有効期限とトークンの exp が一致" \
  "$(python3 -c 'import base64,json,sys; p=open(sys.argv[1]).read().split(".")[1]; print(json.loads(base64.urlsafe_b64decode(p + "=" * (-len(p) % 4)))["exp"])' "$TOKEN_FILE")" \
  "$(jq -r .validity.expires_at.epoch "$META_FILE")"
check "画面に有効期限を表示" grep -q 'Expires At (exp)' "$WORK/stdout"
check "画面に JMeter 設定例を表示" grep -qF '${__FileToString(' "$WORK/stdout"
check "画面にトークン全文を表示しない" bash -c '! grep -qF "$(cat "$1")" "$2"' _ "$TOKEN_FILE" "$WORK/stdout"

echo "== POST 認証 / clientcredentials 表記 / スコープ複数回指定"
OUT="$WORK/post"
run "${COMMON[@]}" -a post -g clientcredentials -S my-api/read -S my-api/write -o "$OUT"
check_eq "終了コード 0" 0 "$RC"
META_FILE="$OUT/cognito_token_latest.meta.json"
check_eq "grant_type を client_credentials に正規化" "client_credentials" "$(jq -r .request.grant_type "$META_FILE")"
check_eq "要求スコープ" "my-api/read my-api/write" "$(jq -r .request.requested_scope "$META_FILE")"
check_eq "付与スコープ一覧" '["my-api/read","my-api/write"]' "$(jq -c .claims_summary.scopes "$META_FILE")"
check_eq "client_auth_method" "client_secret_post" "$(jq -r .request.client_auth_method "$META_FILE")"

echo "== properties 形式 / --no-timestamp / --name"
OUT="$WORK/props"
run "${COMMON[@]}" -f properties --no-timestamp -n jmeter_token -o "$OUT"
check_eq "終了コード 0" 0 "$RC"
check "固定名のトークンファイル" test -f "$OUT/jmeter_token.properties"
check "固定名のメタデータファイル" test -f "$OUT/jmeter_token.meta.json"
check "latest リンクを作成しない" test ! -e "$OUT/jmeter_token_latest.properties"
check "authorization プロパティ" grep -q '^authorization=Bearer ey' "$OUT/jmeter_token.properties"
check_eq "access_token プロパティとメタデータの指紋が一致" \
  "$(jq -r .token_fingerprint.sha256 "$OUT/jmeter_token.meta.json")" \
  "$(sed -n 's/^access_token=//p' "$OUT/jmeter_token.properties" | tr -d '\n' | sha256sum | cut -d ' ' -f 1)"
check_eq "JMeter ヘッダ値" '${__P(authorization)}' "$(jq -r .jmeter.header_value "$OUT/jmeter_token.meta.json")"
run "${COMMON[@]}" -f properties --no-timestamp -n jmeter_token -o "$OUT"
check_eq "再実行で上書き (ファイル数 2 のまま)" 2 "$(find "$OUT" -type f | wc -l)"

echo "== csv 形式"
OUT="$WORK/csv"
run "${COMMON[@]}" -f csv -o "$OUT"
check_eq "終了コード 0" 0 "$RC"
check_eq "CSV ヘッダ行" "access_token,token_type,authorization,expires_at_epoch" \
  "$(head -n 1 "$OUT/cognito_token_latest.csv")"
check_eq "CSV 行数" 2 "$(wc -l <"$OUT/cognito_token_latest.csv")"

echo "== --quiet / --keep"
OUT="$WORK/keep"
for _ in 1 2 3 4; do
  run "${COMMON[@]}" -q --keep 2 -o "$OUT"
done
check_eq "終了コード 0" 0 "$RC"
check_eq "quiet 時は標準出力がトークンファイルのパス 1 行のみ" 1 "$(wc -l <"$WORK/stdout")"
check "quiet 時の出力パスが存在する" test -f "$(cat "$WORK/stdout")"
check_eq "quiet 時は INFO を出力しない" 0 "$(grep -c '^\[INFO\]' "$WORK/stderr")"
check_eq "--keep 2 でトークンファイルが 2 世代" 2 "$(find "$OUT" -type f -name 'cognito_token_2*.token' | wc -l)"
check_eq "--keep 2 でメタデータファイルが 2 世代" 2 "$(find "$OUT" -type f -name 'cognito_token_2*.meta.json' | wc -l)"
check "latest リンクが有効" test -f "$OUT/cognito_token_latest.token"

echo "== シークレットの指定方法 / URL のパス補完"
OUT="$WORK/secret"
printf '%s\r\n' "$CLIENT_SECRET" >"$WORK/secret.txt"
run -c "$CLIENT_ID" --client-secret-file "$WORK/secret.txt" -u "http://127.0.0.1:${PORT}" -o "$OUT"
check_eq "--client-secret-file (CRLF) と URL パス補完で成功" 0 "$RC"
check_eq "補完された URL" "$URL" "$(jq -r .request.token_url "$OUT/cognito_token_latest.meta.json")"
COGNITO_CLIENT_SECRET=$CLIENT_SECRET COGNITO_TOKEN_URL=$URL TOKEN_OUTPUT_DIR="$OUT" run -c "$CLIENT_ID" -q
check_eq "環境変数による指定で成功" 0 "$RC"

echo "== エラー系"
OUT="$WORK/error"
run -c "$CLIENT_ID" -s wrong-secret -u "$URL" -o "$OUT"
check_eq "シークレット誤りは終了コード 3" 3 "$RC"
check "invalid_client を表示" grep -q 'invalid_client' "$WORK/stderr"
check_eq "エラー時はファイルを出力しない" 0 "$(find "$OUT" -type f | wc -l)"
run "${COMMON[@]}" -S "other-api/admin" -o "$OUT"
check_eq "許可されていないスコープは終了コード 3" 3 "$RC"
check "invalid_scope を表示" grep -q 'invalid_scope' "$WORK/stderr"
run "${COMMON[@]}" -g authorization_code -o "$OUT"
check_eq "グラントタイプ誤りは終了コード 3" 3 "$RC"
run -c "$CLIENT_ID" -s "$CLIENT_SECRET" -u "http://127.0.0.1:${PORT}/wrong/path" -o "$OUT"
check_eq "URL のパス誤りは終了コード 3" 3 "$RC"
run "${COMMON[@]}" </dev/null
check_eq "出力先未指定は終了コード 1" 1 "$RC"
run -u "$URL" -o "$OUT" </dev/null
check_eq "クライアント ID・シークレット未指定は終了コード 1" 1 "$RC"
run "${COMMON[@]}" -o "$OUT" -f xml
check_eq "不正な --format は終了コード 1" 1 "$RC"
run "${COMMON[@]}" -o "$OUT" -n '../evil'
check_eq "不正な --name は終了コード 1" 1 "$RC"
run "${COMMON[@]}" -o "$OUT" --keep abc
check_eq "不正な --keep は終了コード 1" 1 "$RC"
run "${COMMON[@]}" -o "$OUT" --unknown
check_eq "不明なオプションは終了コード 1" 1 "$RC"
kill "$SERVER_PID" 2>/dev/null
wait "$SERVER_PID" 2>/dev/null
SERVER_PID=""
run "${COMMON[@]}" -o "$OUT" --connect-timeout 2
check_eq "接続失敗は終了コード 3" 3 "$RC"

echo
echo "結果: PASS=${PASS} FAIL=${FAIL}"
((FAIL == 0))
