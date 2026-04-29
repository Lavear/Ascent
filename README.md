# ASCENT: Approximate and Sparse Compute Engine for Neural Tasks

![Status](https://img.shields.io/badge/Status-Active_Development-brightgreen)
![Target](https://img.shields.io/badge/Target-ASIC%20%7C%20FPGA-blue)
![Language](https://img.shields.io/badge/Language-Verilog%20%7C%20Python-orange)

**ASCENT** (formerly EcoMAC) is a hardware-efficient neural network accelerator designed for low-power Edge AI applications. It directly addresses the memory-wall bottleneck and high dynamic power consumption of traditional AI hardware by integrating three core architectural pillars: **Digital Compute-in-Memory (CIM)**, **Sparse-Aware Scheduling**, and **Approximate Computing**.

This project implements an end-to-end flow from software-level model optimization (pruning and quantization) to RTL design, verification, and ASIC synthesis.

## 🧠 Core Architectural Pillars

1. **Digital Compute-in-Memory (CIM):** A 128x8 row-broadcast SRAM array where weights are stored locally with their respective compute units. This eliminates the "Von Neumann Bottleneck" by ensuring heavy weight data never traverses a system bus.
2. **Sparse Scheduling (Row Gating):** Leverages iterative magnitude pruning (60% sparsity). A custom Control FSM acts as a smart gatekeeper, bypassing all read and compute cycles for zero-weight rows to drastically reduce dynamic switching power.
3. **Approximate Computing:** Replaces traditional, hardware-expensive MAC units with simplified 8x8 signed multipliers using Lower-part OR Approximation (LOA). This bounds computational error to ≤ 5% while achieving massive reductions in critical path delay and logic area.

## 📂 Repository Structure

```text
Ascent/
├── docs/       # Project documentation, block diagrams, and literature survey
├── fpga/       # FPGA specific constraints, bitstreams, and board files (Target: 50MHz)
├── python/     # Pre-silicon modeling: PyTorch/TensorFlow scripts for training, 60% pruning, and 8-bit quantization
├── rtl/        # Verilog/SystemVerilog source files (CIM Array, LOA Multipliers, Sparse Controller, Accumulator Tree)
├── sim/        # Simulation scripts, waveform configurations, and Cadence Xcelium setup
├── synth/      # Synthesis constraints (SDC), setup scripts, and PPA reports (Cadence Genus)
└── tb/         # Testbenches and test vectors (Golden Reference data from Python model)
