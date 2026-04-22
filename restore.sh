#!/usr/bin/env bash
# Supabase 備份還原腳本
#
# 用法：
#   ./restore.sh list
#   ./restore.sh latest
#   ./restore.sh 2026-04-21_1400
#
# 必要環境變數（建議放 .env 然後 `source .env`）：
#   TARGET_DB_URL
#   B2_KEY_ID
#   B2_APPLICATION_KEY
#   B2_ENDPOINT
#   B2_BUCKET

set -euo pipefail

: "${TARGET_DB_URL:?需要 TARGET_DB_URL}"
: "${B2_KEY_ID:?需要 B2_KEY_ID}"
: "${B2_APPLICATION_KEY:?需要 B2_APPLICATION_KEY}"
: "${B2_ENDPOINT:?需要 B2_ENDPOINT}"
: "${B2_BUCKET:?需要 B2_BUCKET}"

export AWS_ACCESS_KEY_ID="$B2_KEY_ID"
export AWS_SECRET_ACCESS_KEY="$B2_APPLICATION_KEY"
export AWS_DEFAULT_REGION=auto

CMD="${1:-latest}"

cmd_list() {
  echo "📦 B2 上的備份清單："
  aws s3api list-objects-v2 \
    --bucket "$B2_BUCKET" \
    --endpoint-url "$B2_ENDPOINT" \
    --prefix "backup_" \
    --query 'Contents[].[Key,Size,LastModified]' \
    --output table
}

get_latest_key() {
  aws s3api list-objects-v2 \
    --bucket "$B2_BUCKET" \
    --endpoint-url "$B2_ENDPOINT" \
    --prefix "backup_" \
    --query 'Contents[].Key' \
    --output text | tr '\t' '\n' | sort | tail -n 1
}

download() {
  local key="$1"
  echo "⬇️  下載 ${key}..."
  aws s3 cp "s3://${B2_BUCKET}/${key}" "./${key}" --endpoint-url "$B2_ENDPOINT"
}

restore_dump() {
  local file="$1"
  echo ""
  echo "⚠️  準備還原到目標資料庫"
  echo "   檔案：${file}"
  echo "   目標：${TARGET_DB_URL%%@*}@***"
  echo ""
  read -p "❓ 這會 DROP 目標資料庫現有的 objects，確定繼續？(yes/NO) " confirm
  if [ "$confirm" != "yes" ]; then
    echo "取消。"
    exit 1
  fi

  echo "🔄 還原中..."
  pg_restore \
    --no-owner \
    --no-acl \
    --no-privileges \
    --clean \
    --if-exists \
    --exit-on-error \
    --verbose \
    --dbname "$TARGET_DB_URL" \
    "$file"

  echo "✅ 還原完成。"
}

case "$CMD" in
  list)
    cmd_list
    ;;
  latest)
    KEY=$(get_latest_key)
    if [ -z "$KEY" ] || [ "$KEY" = "None" ]; then
      echo "❌ 找不到任何備份。" >&2
      exit 1
    fi
    echo "📌 最新備份：${KEY}"
    download "$KEY"
    restore_dump "$KEY"
    ;;
  *)
    KEY="backup_${CMD}.dump"
    download "$KEY"
    restore_dump "$KEY"
    ;;
esac
