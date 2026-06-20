#!/bin/bash

echo "=== STARTING GPU IRQ INTERRUPT PINNING ==="

# Track whether irqbalance was running so we can restore it later
IRQBALANCE_WAS_ACTIVE=false
if systemctl is-active --quiet irqbalance; then
    IRQBALANCE_WAS_ACTIVE=true
fi

# Stop irqbalance before we pin anything. irqbalance does NOT respect manual
# smp_affinity writes — it will overwrite them on every cycle. We must ban the
# R9700 IRQs via --banirq (see systemd drop-in created below).
if [ "$IRQBALANCE_WAS_ACTIVE" = true ]; then
    echo "Temporarily stopping irqbalance service..."
    systemctl stop irqbalance
fi

# Auto-discover all R9700 GPUs via lspci (same method as tune_r9700.sh)
PCI_IDS=()
while IFS= read -r line; do
    BUS_ID=$(echo "$line" | grep -oP '^\S+')
    PCI_IDS+=("0000:$BUS_ID")
done < <(lspci | grep -i R9700)

if [ ${#PCI_IDS[@]} -eq 0 ]; then
    echo "[FAIL] No R9700 GPUs found via lspci."
    exit 1
fi

echo "Discovered ${#PCI_IDS[@]} R9700 GPU(s): ${PCI_IDS[*]}"

# Resolve each PCI device to its card name and IRQ
declare -a GPU_IRQS
declare -a GPU_CARDS

for PCI_ID in "${PCI_IDS[@]}"; do
    if [ ! -d "/sys/bus/pci/devices/$PCI_ID/drm" ]; then
        echo "[FAIL] PCI Device $PCI_ID not found or has no DRM driver attached."
        continue
    fi

    CARD_NAME=$(ls "/sys/bus/pci/devices/$PCI_ID/drm" | grep -E '^card[0-9]+$' | head -n 1)
    if [ -z "$CARD_NAME" ]; then
        echo "[FAIL] Could not determine card name for $PCI_ID"
        continue
    fi

    CARD_PATH="/sys/class/drm/$CARD_NAME"
    IRQ=$(cat "$CARD_PATH/device/irq" 2>/dev/null)

    if [ -z "$IRQ" ]; then
        echo "[FAIL] Could not read IRQ for $CARD_NAME ($PCI_ID)"
        continue
    fi

    GPU_IRQS+=("$IRQ")
    GPU_CARDS+=("$CARD_NAME")
    echo "  $CARD_NAME ($PCI_ID) -> IRQ $IRQ"
done

if [ ${#GPU_IRQS[@]} -eq 0 ]; then
    echo "[FAIL] No valid R9700 IRQs discovered."
    exit 1
fi

echo "---"

# Determine total CPU count and pin to the HIGHEST-numbered cores (in increasing order)
NUM_CPUS=$(nproc)
NUM_GPUS=${#GPU_IRQS[@]}
echo "Total CPUs detected: $NUM_CPUS"

BANNED_MASK=0
idx=0
for IRQ in "${GPU_IRQS[@]}"; do
    TARGET_CPU=$(( NUM_CPUS - NUM_GPUS + idx ))
    if [ "$TARGET_CPU" -lt 0 ]; then
        echo "[FAIL] More IRQs than available CPUs. Aborting."
        exit 1
    fi

    MASK_HEX=$(printf "%x" $((1 << TARGET_CPU)))
    CARD="${GPU_CARDS[$idx]}"
    BANNED_MASK=$(( BANNED_MASK | (1 << TARGET_CPU) ))

    echo "Mapping GPU $CARD (IRQ $IRQ) -> CPU $TARGET_CPU (Bitmask: $MASK_HEX)"
    echo "$MASK_HEX" > "/proc/irq/$IRQ/smp_affinity"
    ((idx++))
done

# Re-pin any non-R9700 amdgpu devices (e.g., iGPU) that landed on a
# dedicated core. Move them to the highest available CPU not in our banned set.
declare -A R9700_IRQ_MAP
for irq in "${GPU_IRQS[@]}"; do
    R9700_IRQ_MAP[$irq]=1
done

while IFS= read -r line; do
    IRQ_NUM=$(echo "$line" | awk -F: '{print $1}' | tr -d ' ')
    PCI_SLOT=$(echo "$line" | grep -oP '0000:[0-9a-f]+:[0-9a-f]+\.0')
    if [ -z "$IRQ_NUM" ] || [ -z "$PCI_SLOT" ]; then
        continue
    fi

    # Skip if this IRQ belongs to one of our R9700 GPUs
    [ "${R9700_IRQ_MAP[$IRQ_NUM]}" = "1" ] && continue

    # Check current affinity — skip if already off all dedicated cores
    CURRENT_AFF=$(cat "/proc/irq/$IRQ_NUM/smp_affinity" 2>/dev/null) || continue
    CURRENT_DEC=$((16#$CURRENT_AFF))
    if [ $(( CURRENT_DEC & BANNED_MASK )) -eq 0 ]; then
        continue
    fi

    # Find highest CPU not in the banned set
    NEW_CPU=$(( NUM_CPUS - 1 ))
    while [ "$NEW_CPU" -ge 0 ] && [ $(( (1 << NEW_CPU) & BANNED_MASK )) -ne 0 ]; do
        ((NEW_CPU--))
    done

    if [ "$NEW_CPU" -ge 0 ]; then
        NEW_HEX=$(printf "%x" $((1 << NEW_CPU)))
        echo "Re-pinning non-R9700 amdgpu (IRQ $IRQ_NUM, PCI $PCI_SLOT) -> CPU $NEW_CPU (Bitmask: $NEW_HEX)"
        echo "$NEW_HEX" > "/proc/irq/$IRQ_NUM/smp_affinity"
    else
        echo "[WARN] No free CPU available to re-pin non-R9700 amdgpu IRQ $IRQ_NUM"
    fi
done < <(grep -i amdgpu /proc/interrupts)

# Set banned CPUs via environment variables — the only mechanism irqbalance
# actually reads. Writing to /etc/irqbalance/banned_cpus is a no-op.
if [ "$BANNED_MASK" -gt 0 ]; then
    BANNED_HEX=$(printf "%x" "$BANNED_MASK")

    # Build a cpulist string (e.g., "56-59,63") from the banned mask
    BANNED_LIST=""
    RANGE_START=-1
    RANGE_PREV=-1
    for (( cpu = 0; cpu < NUM_CPUS; cpu++ )); do
        if [ $(( (1 << cpu) & BANNED_MASK )) -ne 0 ]; then
            if [ "$RANGE_PREV" -eq -1 ]; then
                RANGE_START=$cpu
                RANGE_PREV=$cpu
            elif [ "$cpu" -eq "$(( RANGE_PREV + 1 ))" ]; then
                RANGE_PREV=$cpu
            else
                if [ "$RANGE_START" -eq "$RANGE_PREV" ]; then
                    BANNED_LIST="${BANNED_LIST}${RANGE_START},"
                else
                    BANNED_LIST="${BANNED_LIST}${RANGE_START}-${RANGE_PREV},"
                fi
                RANGE_START=$cpu
                RANGE_PREV=$cpu
            fi
        fi
    done
    if [ "$RANGE_PREV" -ne -1 ]; then
        if [ "$RANGE_START" -eq "$RANGE_PREV" ]; then
            BANNED_LIST="${BANNED_LIST}${RANGE_START},"
        else
            BANNED_LIST="${BANNED_LIST}${RANGE_START}-${RANGE_PREV},"
        fi
    fi
    BANNED_LIST="${BANNED_LIST%,}"

    echo "Banning CPUs from irqbalance: mask=$BANNED_HEX cpulist=$BANNED_LIST"
    systemctl set-environment "IRQBALANCE_BANNED_CPUS=$BANNED_HEX"
    systemctl set-environment "IRQBALANCE_BANNED_CPULIST=$BANNED_LIST"
fi

# Ban the R9700 IRQs from being touched by irqbalance via a systemd drop-in.
# --banirq is the only way to prevent irqbalance from overriding our pins;
# there is no environment variable equivalent.
DROPIN_DIR="/etc/systemd/system/irqbalance.service.d"
DROPIN_FILE="$DROPIN_DIR/pin_gpu_irqs.conf"
mkdir -p "$DROPIN_DIR"

BAN_ARGS=""
for IRQ in "${GPU_IRQS[@]}"; do
    BAN_ARGS+=" --banirq=$IRQ"
done

echo "[Service]" > "$DROPIN_FILE"
echo "ExecStart=" >> "$DROPIN_FILE"
echo "ExecStart=/usr/sbin/irqbalance$BAN_ARGS" >> "$DROPIN_FILE"

echo "Created systemd drop-in at $DROPIN_FILE: $BAN_ARGS"
systemctl daemon-reload

# Restore irqbalance — it will now skip the banned R9700 IRQs and respect
# the IRQBALANCE_BANNED_CPUS/IRQBALANCE_BANNED_CPULIST environment variables.
if [ "$IRQBALANCE_WAS_ACTIVE" = true ]; then
    echo "Restarting irqbalance service..."
    systemctl start irqbalance
fi

echo "=== IRQ PINNING COMPLETE ==="
exit 0
