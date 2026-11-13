#!/bin/sh
# Makes the S3 keys and buckets of Loki and Mimir through the Garage admin
# API (v2). Idempotent: it only adds what is missing, it deletes nothing.
set -eu

apk add --no-cache curl jq >/dev/null

API=http://garage.garage.svc.cluster.local:3903
AUTH="Authorization: Bearer ${GARAGE_ADMIN_TOKEN}"
OUT=/tmp/out

get() {
  curl -sS -o "$OUT" -w '%{http_code}' -H "$AUTH" "$API$1"
}

post() {
  curl -sS -o "$OUT" -w '%{http_code}' -H "$AUTH" \
    -H 'Content-Type: application/json' -d "$2" "$API$1"
}

check() {
  case "$1" in
    2??) ;;
    *) echo "HTTP $1: $(cat "$OUT")" >&2; exit 1 ;;
  esac
}

# $1 name, $2 key ID, $3 secret key
ensure_key() {
  code=$(get "/v2/GetKeyInfo?id=$2")
  if [ "$code" = 404 ]; then
    body=$(jq -n --arg n "$1" --arg id "$2" --arg s "$3" \
      '{name: $n, accessKeyId: $id, secretAccessKey: $s}')
    check "$(post /v2/ImportKey "$body")"
    echo "key $1: imported"
  else
    check "$code"
    echo "key $1: exists"
  fi
}

# $1 bucket, $2 key ID that gets read, write and owner
ensure_bucket() {
  code=$(get "/v2/GetBucketInfo?globalAlias=$1")
  if [ "$code" = 404 ]; then
    check "$(post /v2/CreateBucket "$(jq -n --arg b "$1" '{globalAlias: $b}')")"
    echo "bucket $1: created"
  else
    check "$code"
    echo "bucket $1: exists"
  fi
  id=$(jq -r .id "$OUT")
  body=$(jq -n --arg b "$id" --arg k "$2" \
    '{bucketId: $b, accessKeyId: $k, permissions: {read: true, write: true, owner: true}}')
  check "$(post /v2/AllowBucketKey "$body")"
  echo "bucket $1: allowed for $2"
}

until [ "$(curl -s -o /dev/null -w '%{http_code}' "$API/health")" = 200 ]; do
  echo "waiting for $API/health"
  sleep 5
done

ensure_key loki "$LOKI_ACCESS_KEY_ID" "$LOKI_SECRET_ACCESS_KEY"
ensure_key mimir "$MIMIR_ACCESS_KEY_ID" "$MIMIR_SECRET_ACCESS_KEY"

ensure_bucket loki-chunks "$LOKI_ACCESS_KEY_ID"
ensure_bucket loki-ruler "$LOKI_ACCESS_KEY_ID"
ensure_bucket mimir "$MIMIR_ACCESS_KEY_ID"
