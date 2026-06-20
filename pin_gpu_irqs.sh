#!/bin/bash

echo "=== STARTING GPU IRQ INTERRUPT PINNING ==="

# Track whether irqbalance was running so we can restore it later
IRQBALANCE_WAS_ACTIVE=false
if systemctl is-active --quiet irqbalance; then
    IRQBALANCE_WAS_ACTIVE=true
fi

if [ "$IRQBALANCE_WAS_ACTIVE" = true ]; then
    echo "Temporarily stopping irqbalance service..."
    systemctl stop irqbalance
fi

# Auto-discover all R9700 GPUs via lspci
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

# Determine physical CPU allocation
NUM_CPUS=$(nproc)
NUM_GPUS=${#GPU_IRQS[@]}
echo "Total CPUs detected: $NUM_CPUS"

BANNED_CPUS_ARR=()
idx=0
for IRQ in "${GPU_IRQS[@]}"; do
    # Pin to the highest physical cores
    TARGET_CPU=$(( NUM_CPUS - NUM_GPUS + idx ))
    if [ "$TARGET_CPU" -lt 0 ]; then
        echo "[FAIL] More IRQs than available CPUs. Aborting."
        exit 1
    fi

    CARD="${GPU_CARDS[$idx]}"
    BANNED_CPUS_ARR+=("$TARGET_CPU")

    echo "Mapping GPU $CARD (IRQ $IRQ) -> CPU $TARGET_CPU"
    # Hardened approach: use smp_affinity_list to completely avoid hex-shifting bugs
    echo "$TARGET_CPU" > "/proc/irq/$IRQ/smp_affinity_list"
    ((idx++))
done

# Build the comma-separated CPU list and compute hex mask safely via bc
BANNED_LIST=$(IFS=,; echo "${BANNED_CPUS_ARR[*]}")
BANNED_MASK_DEC=0
for cpu in "${BANNED_CPUS_ARR[@]}"; do
    BANNED_MASK_DEC=$(echo "$BANNED_MASK_DEC + 2^$cpu" | bc)
done
BANNED_HEX=$(echo "obase=16; $BANNED_MASK_DEC" | bc | tr 'A-Z' 'a-z')

# Re-pin any conflicting non-R9700 amdgpu devices (like an iGPU)
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

    [ "${R9700_IRQ_MAP[$IRQ_NUM]}" = "1" ] && continue

    CURRENT_LIST=$(cat "/proc/irq/$IRQ_NUM/smp_affinity_list" 2>/dev/null) || continue
    
    # Check if the conflicting IRQ lands on any of our isolated cores
    CONFLICT=false
    for cpu in "${BANNED_CPUS_ARR[@]}"; do
        if [[ ",$CURRENT_LIST," == *",$cpu,"* ]]; then
            CONFLICT=true
            break
        fi
    done

    if [ "$CONFLICT" = true ]; then
        # Find the highest safe core
        NEW_CPU=$(( NUM_CPUS - 1 ))
        while [[ " ${BANNED_CPUS_ARR[*]} " == *" $NEW_CPU "* ]] && [ "$NEW_CPU" -ge 0 ]; do
            ((NEW_CPU--))
        done

        if [ "$NEW_CPU" -ge 0 ]; then
            echo "Re-pinning non-R9700 amdgpu (IRQ $IRQ_NUM, PCI $PCI_SLOT) -> CPU $NEW_CPU"
            echo "$NEW_CPU" > "/proc/irq/$IRQ_NUM/smp_affinity_list"
        fi
    fi
done < <(grep -i amdgpu /proc/interrupts)

# Inject environment overrides to irqbalance
echo "Banning CPUs from irqbalance: mask=$BANNED_HEX cpulist=$BANNED_LIST"
systemctl set-environment "IRQBALANCE_BANNED_CPUS=$BANNED_HEX"
systemctl set-environment "IRQBALANCE_BANNED_CPULIST=$BANNED_LIST"

# Maintain systemd drop-in for explicit IRQ banning
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

if [ "$IRQBALANCE_WAS_ACTIVE" = true ]; then
    echo "Restarting irqbalance service..."
    systemctl start irqbalance
fi

echo "=== IRQ PINNING COMPLETE ==="
exit 0

