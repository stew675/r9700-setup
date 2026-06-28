# AMD AI Pro R9700 ROCm Tuning Guide (Fedora Linux)

A collection of scripts, systemd services, and configuration tips for optimizing multiple AMD AI Pro R9700 GPUs on Fedora Linux for AI workloads like `llama.cpp` and `vLLM`.

## Table of Contents
1. [Prerequisites](#prerequisites)
2. [Kernel Boot Parameters](#kernel-boot-parameters)
3. [GPU Tuning: Undervolting & Power Limits](#gpu-tuning-undervolting--power-limits)
4. [IRQ Pinning & Isolation](#irq-pinning--isolation)
5. [Compiling llama.cpp with ROCm](#compiling-llamacpp-with-rocm)
6. [vLLM Setup](#vllm-setup)

---

## Prerequisites

Ensure you have the latest AMD ROCm drivers installed for your Fedora installation. You will also need the following development libraries to compile ROCm-accelerated AI tools:

```bash
sudo dnf install hip-devel hipblas hipblas-devel rocblas rocblas-devel rccl rccl-devel rocwmma-devel
```

---

## Kernel Boot Parameters

To enable advanced power management features (like undervolting) and ensure stability, specific kernel parameters are required.

### Key Flags
- `processor.max_cstate=2`: Limits CPU C-states to reduce latency spikes during inference.
- `pcie_aspm=off`: Disables PCIe Active State Power Management for consistent GPU bandwidth and stability.
- `amdgpu.ppfeaturemask=0xffffffff`: Unlocks all AMDGPU power management features (required for undervolting).

### Installation
1. Edit your GRUB configuration:
   ```bash
   sudo nano /etc/default/grub
   ```
2. Append the flags to the `GRUB_CMDLINE_LINUX` line:
   ```text
   GRUB_CMDLINE_LINUX="... processor.max_cstate=2 pcie_aspm=off amdgpu.ppfeaturemask=0xffffffff"
   ```
3. Update GRUB configuration and reboot:
   ```bash
   sudo grub2-mkconfig -o /boot/grub2/grub.cfg
   sudo reboot
   ```

*A reference configuration file (`grub`) is included in this repo.

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

### Step 1: Clone llama.cpp
First, clone the official `llama.cpp` repository if you haven't already:

```bash
git clone https://github.com/ggml-org/llama.cpp.git
cd llama.cpp
```

### Step 2: Build with ROCm Optimizations
You have two options: use the provided script or run the commands manually.

#### Option A: Using the provided script
Copy the `build-llama-rocm` script from this repository into your `llama.cpp` directory and execute it:

```bash
# Assuming you are in the llama.cpp directory
cp /path/to/r9700-setup/build-llama-rocm ./
chmod +x build-llama-rocm
./build-llama-rocm
```

#### Option B: Manual Build Commands
If you prefer to run the commands manually, execute the following inside your `llama.cpp` directory. This configures CMake with flags for RPC, RCCL (multi-GPU), RDNA 4 targets (`gfx1201`), and Flash Attention via ROCWMMA.

```bash
rm -rf build

HIPCXX="$(hipconfig -l)/clang" HIP_PATH="$(hipconfig -R)" cmake -S . -B build \
  -DGGML_RPC=1 \
  -DGGML_HIP=ON \
  -DGGML_NATIVE=1 \
  -DGGML_HIP_RCCL=ON \
  -DCMAKE_C_COMPILER=clang \
  -DCMAKE_BUILD_TYPE=Release \
  -DGGML_CUDA_NO_PEER_COPY=1 \
  -DGGML_HIP_ROCWMMA_FATTN=ON \
  -DCMAKE_CXX_COMPILER=clang++ \
  -DGPU_TARGETS="gfx1200;gfx1201" \
  -DCMAKE_INSTALL_RPATH="$ORIGIN" \
  -DAMDGPU_TARGETS="gfx1200;gfx1201" \
  -DCMAKE_BUILD_WITH_INSTALL_RPATH=ON

cmake --build build --config Release -j $(nproc) -- VERBOSE=1
```

### Key Build Flags Explained
- `-DGGML_RPC=1`: Enables Remote Procedure Call for distributed inference.
- `-DGGML_HIP_RCCL=ON`: Uses ROCm Collective Communications Library for multi-GPU scaling.
- `-DGPU_TARGETS="gfx1200;gfx1201"`: Compiles kernels specifically for RDNA 4 GPUs (R9700).
- `-DGGML_HIP_ROCWMMA_FATTN=ON`: Enables Flash Attention via ROCWMMA for faster attention layers.
- `-DGGML_CUDA_NO_PEER_COPY=1`: Disables peer-to-peer memory copy (recommended if P2P is unstable in your topology).
---

## vLLM Setup

For users looking to deploy R9700 GPUs with vLLM, the following guide is highly recommended for ease of use and comprehensive setup:

👉 **[kyuz0/amd-r9700-vllm-toolboxes](https://github.com/kyuz0/amd-r9700-vllm-toolboxes/tree/main)**

---

## Testing

The repository includes `test-prompt-1` and `test-prompt-2` which can be used to verify inference quality and performance after setup.
