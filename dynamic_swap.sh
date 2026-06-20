#!/bin/bash

echo "=== STARTING CONDITIONAL SWAP MANAGEMENT ==="

# Extract total physical memory in Kilobytes from /proc/meminfo
TOTAL_MEM_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')

# 128 GB in Kilobytes = 128 * 1024 * 1024 = 134217728 KB
THRESHOLD_KB=134217728

echo "Detected Host Physical Memory: $((TOTAL_MEM_KB / 1024 / 1024)) GB"

if [ "$TOTAL_MEM_KB" -gt "$THRESHOLD_KB" ]; then
    echo "Memory exceeds 128GB threshold. Checking for active disk swap..."
    
    # Check if /dev/sda3 is currently active in the swap pool
    if swapon --show=NAME | grep -q "/dev/sda3"; then
        if swapoff /dev/sda3; then
            echo "[SUCCESS] /dev/sda3 has been safely unmounted to maximize silicon bus speeds."
        else
            echo "[FAIL] Failed to unmount /dev/sda3."
            exit 1
        fi
    else
        echo "/dev/sda3 is already unmounted or inactive. No action needed."
    fi
else
    echo "Host memory is equal to or under 128GB. Retaining /dev/sda3 for safety headroom."
fi

echo "=== SWAP MANAGEMENT COMPLETE ==="
exit 0

