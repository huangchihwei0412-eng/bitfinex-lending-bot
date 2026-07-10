#!/usr/bin/env bash
set -euo pipefail

DISPLAY_NAME="lending-bot-vm"
COMPARTMENT_ID="$OCI_TENANCY_OCID"
SUBNET_ID="$OCI_SUBNET_OCID"
SHAPE="VM.Standard.A1.Flex"
OCPUS=1
MEMORY_GB=6

echo "檢查是否已有同名執行中的執行個體..."
EXISTING=$(oci compute instance list \
  --compartment-id "$COMPARTMENT_ID" \
  --display-name "$DISPLAY_NAME" \
  --lifecycle-state RUNNING \
  --query "data[0].id" --raw-output 2>/dev/null || echo "null")

if [ "$EXISTING" != "null" ] && [ -n "$EXISTING" ]; then
  echo "✅ 已經有執行中的 VM 了: $EXISTING"
  exit 0
fi

echo "取得可用性網域..."
AD=$(oci iam availability-domain list \
  --compartment-id "$COMPARTMENT_ID" \
  --query "data[0].name" --raw-output)
echo "使用 AD: $AD"

echo "取得 Ubuntu 24.04 映像檔..."
IMAGE_ID=$(oci compute image list \
  --compartment-id "$COMPARTMENT_ID" \
  --operating-system "Canonical Ubuntu" \
  --operating-system-version "24.04" \
  --shape "$SHAPE" \
  --sort-by TIMECREATED --sort-order DESC \
  --query "data[0].id" --raw-output)
echo "使用映像檔: $IMAGE_ID"

echo "嘗試建立執行個體..."
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
  --ssh-authorized-keys-file <(echo "$OCI_SSH_PUBLIC_KEY") \
  --wait-for-state RUNNING \
  --max-wait-seconds 180 2>&1)
STATUS=$?
set -e

echo "$RESULT"

if [ $STATUS -eq 0 ]; then
  echo "🎉 VM 建立成功！"
  exit 0
elif echo "$RESULT" | grep -qi "OutOfCapacity\|Out of host capacity"; then
  echo "⏳ 容量不足，等下一輪排程再試"
  exit 0
else
  echo "❌ 發生非預期錯誤"
  exit 1
fi
