#!/bin/bash

# --- CONFIGURATION ---
UNDERVOLT_MV=-85
POWER_LIMIT_WATT=265
POWER_LIMIT_HW=$(($POWER_LIMIT_WATT * 1000000))

# ---------------------

# Auto-discover all R9700 GPUs via lspci
PCI_IDS=()
while IFS= read -r line; do
    BUS_ID=$(echo "$line" | grep -oP '^\S+')
    PCI_IDS+=("0000:$BUS_ID")
done < <(lspci | grep -i R9700)

if [ ${#PCI_IDS[@]} -eq 0 ]; then
    echo "Error: No R9700 GPUs found."
    exit 1
fi

echo "Discovered ${#PCI_IDS[@]} R9700 GPU(s): ${PCI_IDS[*]}"
echo "---"

# Arrays to store resolved paths for verification
declare -a CARD_NAMES
declare -a HWMON_DIRS

tune_card() {
    local PCI_ID="$1"
    local idx="$2"

    # 1. Find the Card Name (e.g., card1) from the PCI Bus
    if [ ! -d "/sys/bus/pci/devices/$PCI_ID/drm" ]; then
        echo "[FAIL] PCI Device $PCI_ID not found or has no DRM driver attached."
        return 1
    fi

    local CARD_NAME
    CARD_NAME=$(ls "/sys/bus/pci/devices/$PCI_ID/drm" | grep -E '^card[0-9]+$' | head -n 1)

    if [ -z "$CARD_NAME" ]; then
        echo "[FAIL] Could not determine card name for $PCI_ID"
        return 1
    fi

    local CARD_PATH="/sys/class/drm/$CARD_NAME"
    CARD_NAMES[$idx]="$CARD_NAME"
    echo "Tuning GPU: $CARD_NAME ($PCI_ID)..."

    # 2. Force Manual Performance Level (Required for UV)
    echo "manual" | tee "$CARD_PATH/device/power_dpm_force_performance_level" > /dev/null
    if [ $? -ne 0 ]; then
        echo "[FAIL] Failed to set Manual mode for $CARD_NAME."
        return 1
    fi

    # 3. Apply Undervolt
    echo "vo $UNDERVOLT_MV" | tee "$CARD_PATH/device/pp_od_clk_voltage" > /dev/null
    echo "c" | tee "$CARD_PATH/device/pp_od_clk_voltage" > /dev/null
    echo "  -> Applied Undervolt (${UNDERVOLT_MV}mV)"

    # 4. Set Power Limit
    local HWMON_DIR
    HWMON_DIR=$(find "$CARD_PATH/device/hwmon" -mindepth 1 -maxdepth 1 -type d -name "hwmon*" | head -n 1)
    if [ -n "$HWMON_DIR" ] && [ -e "$HWMON_DIR/power1_cap" ]; then
        if echo "$POWER_LIMIT_HW" | tee "$HWMON_DIR/power1_cap" > /dev/null; then
            echo "  -> Applied Power Limit (${POWER_LIMIT_WATT}W)"
            HWMON_DIRS[$idx]="$HWMON_DIR"
        else
            echo "[FAIL] Failed to apply Power Limit for $CARD_NAME."
            return 1
        fi
    else
        echo "[FAIL] Could not find writable power1_cap under hwmon for $CARD_NAME."
        return 1
    fi

    echo "  -> Done."
    return 0
}

# Tune each discovered card
FAILED=0
idx=0
for PCI_ID in "${PCI_IDS[@]}"; do
    tune_card "$PCI_ID" "$idx" || ((FAILED++))
    echo "---"
    ((idx++))
done

if [ $FAILED -gt 0 ]; then
    echo "Completed with $FAILED failure(s)."
    exit 1
fi

echo "All GPUs tuned successfully."
echo ""
echo "=== VERIFICATION ==="

for i in "${!CARD_NAMES[@]}"; do
    CARD_NAME="${CARD_NAMES[$i]}"
    CARD_PATH="/sys/class/drm/$CARD_NAME"
    echo "--- $CARD_NAME ---"

    # Check Undervolt (label and value are on separate lines)
    UV_OUTPUT=$(cat "$CARD_PATH/device/pp_od_clk_voltage" 2>/dev/null)
    if [ -n "$UV_OUTPUT" ]; then
        OFFSET_LINE=$(echo "$UV_OUTPUT" | grep -A1 "^OD_VDDGFX_OFFSET:")
        if [ -n "$OFFSET_LINE" ]; then
            OFFSET_VAL=$(echo "$OFFSET_LINE" | tail -n1 | xargs)
            echo "  Undervolt: OD_VDDGFX_OFFSET: $OFFSET_VAL"
        else
            echo "  Undervolt: (could not parse offset from output)"
        fi
    else
        echo "  Undervolt: (unable to read)"
    fi

    # Check Power Limit
    if [ -n "${HWMON_DIRS[$i]}" ]; then
        POWER_RAW=$(cat "${HWMON_DIRS[$i]}/power1_cap" 2>/dev/null)
        if [ -n "$POWER_RAW" ]; then
            POWER_W=$((POWER_RAW / 1000000))
            echo "  Power Limit: ${POWER_W}W (target: ${POWER_LIMIT_WATT}W)"
        else
            echo "  Power Limit: (unable to read)"
        fi
    else
        echo "  Power Limit: (hwmon path not available)"
    fi
done

echo ""
echo "=== DONE ==="
