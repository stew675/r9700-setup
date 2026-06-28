# AMD AI Pro R9700 ROCm Tuning Guide (Fedora Linux)

A collection of scripts, systemd services, and configuration tips for optimizing multiple AMD AI Pro R9700 GPUs on Fedora Linux for AI workloads like `llama.cpp` and `vLLM`.

## Table of Contents
1. [Prerequisites](#prerequisites)
2. [GPU Tuning: Undervolting & Power Limits](#gpu-tuning-undervolting--power-limits)
3. [IRQ Pinning & Isolation](#irq-pinning--isolation)
4. [Compiling llama.cpp with ROCm](#compiling-llamacpp-with-rocm)
5. [vLLM Setup](#vllm-setup)

---

## Prerequisites

Ensure you have the latest AMD ROCm drivers installed for your Fedora installation. You will also need the following development libraries to compile ROCm-accelerated AI tools:

```bash
sudo dnf install hip-devel hipblas hipblas-devel rocblas rocblas-devel rccl rccl-devel rocwmma-devel
```

---

## GPU Tuning: Undervolting & Power Limits

To maximize efficiency and thermal headroom, we apply an undervolt and a strict power limit to all detected R9700 GPUs.

### Configuration
- **Undervolt:** -85mV
- **Power Limit:** 265W

### Setup
1. Copy `tune_r9700.sh` to `/usr/local/bin/` and ensure it is executable:
   ```bash
   sudo cp tune_r9700.sh /usr/local/bin/
   sudo chmod +x /usr/local/bin/tune_r9700.sh
   ```
2. Install the systemd service:
   ```bash
   sudo cp amd-gpu-tune.service /etc/systemd/system/
   sudo systemctl daemon-reload
   sudo systemctl enable --now amd-gpu-tune.service
   ```

The script automatically discovers R9700 GPUs via `lspci`, forces manual performance mode, applies the undervolt via `pp_od_clk_voltage`, and sets the power cap.

---

## IRQ Pinning & Isolation

For multi-GPU inference, interrupt handling can become a bottleneck. This setup pins GPU hardware interrupts to dedicated physical cores and prevents `irqbalance` from moving them or assigning other interrupts to those cores.

### How it works
- **Auto-Discovery:** Finds all R9700 GPUs and their associated IRQs.
- **Core Pinning:** Assigns each GPU IRQ to the highest-numbered physical CPU cores.
- **Conflict Resolution:** Re-pins any conflicting `amdgpu` IRQs (e.g., from an iGPU) off the isolated cores.
- **irqbalance Integration:** Bans the isolated cores and specific GPU IRQs from `irqbalance` via environment variables and a systemd drop-in.

### Setup
1. Copy `pin_gpu_irqs.sh` to `/usr/local/bin/` and ensure it is executable:
   ```bash
   sudo cp pin_gpu_irqs.sh /usr/local/bin/
   sudo chmod +x /usr/local/bin/pin_gpu_irqs.sh
   ```
2. Install the systemd service (configured to run *after* GPU tuning):
   ```bash
   sudo cp gpu-irq-pin.service /etc/systemd/system/
   sudo systemctl daemon-reload
   sudo systemctl enable --now gpu-irq-pin.service
   ```

---

## Compiling llama.cpp with ROCm

This repository includes a build script optimized for the R9700's RDNA 4 architecture (`gfx1201`) and multi-GPU setups using RCCL.

### Build Script: `build-llama-rocm`
The script configures CMake with the following key flags:
- `-DGGML_RPC=1`: Enables Remote Procedure Call for distributed inference.
- `-DGGML_HIP_RCCL=ON`: Uses ROCm Collective Communications Library for multi-GPU scaling.
- `-DGPU_TARGETS="gfx1200;gfx1201"`: Compiles kernels for RDNA 4 GPUs.
- `-DGGML_HIP_ROCWMMA_FATTN=ON`: Enables Flash Attention via ROCWMMA for faster attention layers.
- `-DGGML_CUDA_NO_PEER_COPY=1`: Disables peer-to-peer memory copy (recommended if P2P is unstable in your topology).

### Usage
From within the `llama.cpp` source directory:
```bash
# Make sure you are in your llama.cpp root directory
chmod +x /path/to/r9700-rocm-tuning/build-llama-rocm
/path/to/r9700-rocm-tuning/build-llama-rocm
```

---

## vLLM Setup

For users looking to deploy R9700 GPUs with vLLM, the following guide is highly recommended for ease of use and comprehensive setup:

👉 **[kyuz0/amd-r9700-vllm-toolboxes](https://github.com/kyuz0/amd-r9700-vllm-toolboxes/tree/main)**

---

## Testing

The repository includes `test-prompt-1` and `test-prompt-2` which can be used to verify inference quality and performance after setup.
