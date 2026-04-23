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
  read -p "❓ 這會 DROP 目標資料庫 public schema 的現有物件，確定繼續？(yes/NO) " confirm
  if [ "$confirm" != "yes" ]; then
    echo "取消。"
    exit 1
  fi

  echo "🔄 還原中..."
  pg_restore \
    --no-owner \
    --no-acl \
    --no-privileges \
    --no-publications \
    --no-subscriptions \
    --clean \
    --if-exists \
    --verbose \
    --dbname "$TARGET_DB_URL" \
    "$file" 2> restore.log || true

  # 過濾出真正重要的訊息
  echo ""
  echo "═══════════════════════════════════════════════════════════"
  echo "📊 還原結果分析"
  echo "═══════════════════════════════════════════════════════════"

  # 統計各類錯誤
  TOTAL_ERR=$(grep -c "^pg_restore: 錯誤\|^pg_restore: error" restore.log || echo 0)
  SYSTEM_ERR=$(grep -cE "schema (auth|storage|realtime|vault|graphql|graphql_public|pgbouncer|cron|extensions)|pgrst_|supabase_|issue_pg_|Non-superuser owned event trigger|already exists" restore.log || echo 0)
  BUSINESS_ERR=$((TOTAL_ERR - SYSTEM_ERR))

  echo "  系統 schema 噴錯（可忽略）：${SYSTEM_ERR}"
  echo "  業務 schema 噴錯（需檢查）：${BUSINESS_ERR}"
  echo ""

  if [ "$BUSINESS_ERR" -gt 0 ]; then
    echo "⚠️  有 ${BUSINESS_ERR} 筆可能需要關注的錯誤："
    grep "^pg_restore: 錯誤\|^pg_restore: error" restore.log \
      | grep -vE "schema (auth|storage|realtime|vault|graphql|graphql_public|pgbouncer|cron|extensions)|pgrst_|supabase_|issue_pg_|Non-superuser owned event trigger|already exists" \
      | head -20
    echo ""
    echo "   完整 log 在 restore.log"
  else
    echo "✅ public schema 還原無錯誤，完整 log 在 restore.log"
  fi

  echo ""
  echo "👉 下一步：登入 Supabase Dashboard 確認 public 資料表的資料都正常"
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
