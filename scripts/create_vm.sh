#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# 設定區
# ============================================================
DISPLAY_NAME="lending-bot-vm"
COMPARTMENT_ID="$OCI_TENANCY_OCID"
SUBNET_ID="$OCI_SUBNET_OCID"
SHAPE="VM.Standard.A1.Flex"
OCPUS=1
MEMORY_GB=6
MAX_RETRIES=3

STATE_FILE="state/retry_state.json"

# ============================================================
# 共用函式
# ============================================================
send_telegram() {
  curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
    -d chat_id="${TELEGRAM_CHAT_ID}" \
    -d text="$1" > /dev/null
}

# ============================================================
# 初始化狀態檔
# ============================================================
mkdir -p state
if [ ! -f "$STATE_FILE" ]; then
  echo "{\"count\": 0, \"start_time\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\", \"last_summary_slot\": \"\"}" > "$STATE_FILE"
fi

# ============================================================
# 檢查是否已有執行中的 VM（避免重複建立）
# ============================================================
echo "檢查是否已有同名執行中的執行個體..."
EXISTING=$(oci compute instance list \
  --compartment-id "$COMPARTMENT_ID" \
  --display-name "$DISPLAY_NAME" \
  --lifecycle-state RUNNING \
  --query "data[0].id" --raw-output 2>/dev/null || echo "null")

if [ "$EXISTING" != "null" ] && [ -n "$EXISTING" ]; then
  echo "✅ 已經有執行中的 VM 了: $EXISTING"
  rm -f "$STATE_FILE"
  exit 0
fi

# ============================================================
# 取得建立 VM 所需的資源資訊
# ============================================================
echo "取得可用性網域..."
AD=$(oci iam availability-domain list \
  --compartment-id "$COMPARTMENT_ID" \
  --query "data[0].name" --raw-output)

echo "取得 Ubuntu 24.04 映像檔..."
IMAGE_ID=$(oci compute image list \
  --compartment-id "$COMPARTMENT_ID" \
  --operating-system "Canonical Ubuntu" \
  --operating-system-version "24.04" \
  --shape "$SHAPE" \
  --sort-by TIMECREATED --sort-order DESC \
  --query "data[0].id" --raw-output)

# ============================================================
# 嘗試建立 VM（本輪內重試 MAX_RETRIES 次）
# ============================================================
SUCCESS=0

for i in $(seq 1 $MAX_RETRIES); do
  echo "--- 第 $i 次嘗試 ---"

  set +e
  RESULT=$(oci compute instance launch \
    --compartment-id "$COMPARTMENT_ID" \
    --availability-domain "$AD" \
    --shape "$SHAPE" \
    --shape-config "{\"ocpus\": $OCPUS, \"memoryInGBs\": $MEMORY_GB}" \
    --subnet-id "$SUBNET_ID" \
    --image-id "$IMAGE_ID" \
    --display-name "$DISPLAY_NAME" \
    --assign-public-ip true \
    --ssh-authorized-keys-file <(echo "$OCI_SSH_PUBLIC_KEY") 2>&1)
  STATUS=$?
  set -e

  echo "$RESULT"

  if [ $STATUS -eq 0 ]; then
    # 成功
    SUCCESS=1
    break

  elif echo "$RESULT" | grep -qi "OutOfCapacity\|Out of host capacity\|TooManyRequests\|429"; then
    # 容量不足 / API 速率限制：不重試，交由外部排程下一輪再試
    echo "⚠️ 容量不足或觸發速率限制，這輪先結束，交由外部排程 5 分鐘後重試"
    break

  elif echo "$RESULT" | grep -qi "timed out\|timeout\|connection"; then
    # 網路逾時：本輪內重試
    echo "⚠️ 網路連線逾時，10 秒後重試 ($i/$MAX_RETRIES)"
    sleep 10
    continue

  else
    # 非預期錯誤：中止並通知
    echo "❌ 發生非預期錯誤"
    send_telegram "❌ 建立 VM 時發生非預期錯誤，請查看 GitHub Actions log"
    exit 1
  fi
done

# ============================================================
# 讀取目前累計狀態
# ============================================================
COUNT=$(python3 -c "import json;print(json.load(open('$STATE_FILE'))['count'])")
START_TIME=$(python3 -c "import json;print(json.load(open('$STATE_FILE'))['start_time'])")
LAST_SLOT=$(python3 -c "import json;print(json.load(open('$STATE_FILE')).get('last_summary_slot',''))")

# ============================================================
# 成功：通知並清除狀態檔
# ============================================================
if [ $SUCCESS -eq 1 ]; then
  echo "🎉 VM 建立成功！"
  PUBLIC_IP=$(echo "$RESULT" | grep -oP '"public-ip":\s*"\K[^"]+' || echo "未知")
  send_telegram "🎉 Oracle VM 建立成功！公用 IP: ${PUBLIC_IP}（共重試 ${COUNT} 次）"
  rm -f "$STATE_FILE"
  exit 0
fi

# ============================================================
# 未成功：累計次數 +1，並視時段發送彙整通知
# ============================================================
echo "⏳ 這輪未成功，累積次數 +1"
COUNT=$((COUNT + 1))

NOW_UTC_HOUR=$(date -u +%H)
NOW_UTC_MIN=$(date -u +%M)
TODAY=$(date -u +%Y-%m-%d)

SLOT=""
if [ "$NOW_UTC_HOUR" = "00" ] && [ "$NOW_UTC_MIN" -lt 5 ]; then
  SLOT="${TODAY}-0800TW"
elif [ "$NOW_UTC_HOUR" = "12" ] && [ "$NOW_UTC_MIN" -lt 5 ]; then
  SLOT="${TODAY}-2000TW"
fi

if [ -n "$SLOT" ] && [ "$SLOT" != "$LAST_SLOT" ]; then
  START_EPOCH=$(date -u -d "$START_TIME" +%s)
  NOW_EPOCH=$(date -u +%s)
  DIFF=$((NOW_EPOCH - START_EPOCH))
  HOURS=$((DIFF / 3600))
  MINUTES=$(((DIFF % 3600) / 60))
  send_telegram "⏳ VM 搶建進度彙整：已累積嘗試 ${COUNT} 輪，耗時約 ${HOURS} 小時 ${MINUTES} 分鐘，尚未成功，持續重試中"
  LAST_SLOT="$SLOT"
fi

# ============================================================
# 寫回狀態檔
# ============================================================
python3 -c "
import json
json.dump({'count': $COUNT, 'start_time': '$START_TIME', 'last_summary_slot': '$LAST_SLOT'}, open('$STATE_FILE','w'))
"

echo "狀態已更新：累積 $COUNT 次"
exit 0
