#!/usr/bin/env python3
"""get_cognito_token.sh のテスト用 Cognito トークンエンドポイント模擬サーバ.

使い方: mock_cognito_server.py <ポート番号の出力先ファイル>
  127.0.0.1 の空きポートで待ち受け、POST /oauth2/token に対して
  Cognito と同じ形式のレスポンス (署名はダミーの JWT) を返す。
"""
import base64
import json
import sys
import time
import uuid
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import parse_qs

CLIENT_ID = "testclientid0123456789abcd"
CLIENT_SECRET = "testclientsecret0123456789abcdefghijklmnopqrstuvwxy"
ALLOWED_SCOPES = ["my-api/read", "my-api/write"]
ISSUER = "https://cognito-idp.ap-northeast-1.amazonaws.com/ap-northeast-1_TEST00000"
LIFETIME = 3600


def b64url(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


def make_token(scopes):
    now = int(time.time())
    header = {"kid": "test-kid-0001", "alg": "RS256"}
    payload = {
        "sub": CLIENT_ID,
        "token_use": "access",
        "scope": " ".join(scopes),
        "auth_time": now,
        "iss": ISSUER,
        "exp": now + LIFETIME,
        "iat": now,
        "version": 2,
        "jti": str(uuid.uuid4()),
        "client_id": CLIENT_ID,
    }
    return ".".join(
        [
            b64url(json.dumps(header).encode()),
            b64url(json.dumps(payload).encode()),
            b64url(b"dummy-signature"),
        ]
    )


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def send_json(self, status, body):
        data = json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json;charset=UTF-8")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_POST(self):
        if self.path != "/oauth2/token":
            self.send_json(404, {"message": "Not Found"})
            return

        length = int(self.headers.get("Content-Length", "0"))
        form = {k: v[0] for k, v in parse_qs(self.rfile.read(length).decode()).items()}

        client_id = form.get("client_id")
        client_secret = form.get("client_secret")
        auth = self.headers.get("Authorization", "")
        if auth.startswith("Basic "):
            client_id, _, client_secret = base64.b64decode(auth[6:]).decode().partition(":")

        if client_id != CLIENT_ID or client_secret != CLIENT_SECRET:
            self.send_json(400, {"error": "invalid_client"})
            return
        if form.get("grant_type") != "client_credentials":
            self.send_json(400, {"error": "unsupported_grant_type"})
            return

        requested = form.get("scope", "").split()
        if any(s not in ALLOWED_SCOPES for s in requested):
            self.send_json(400, {"error": "invalid_scope"})
            return

        self.send_json(
            200,
            {
                "access_token": make_token(requested or ALLOWED_SCOPES),
                "expires_in": LIFETIME,
                "token_type": "Bearer",
            },
        )


def main():
    server = HTTPServer(("127.0.0.1", 0), Handler)
    with open(sys.argv[1], "w") as f:
        f.write(str(server.server_address[1]))
    server.serve_forever()


if __name__ == "__main__":
    main()
