# Bare-Metal Processor System with Custom Hardware Accelerator
This project was developed as part of the SYKOM course (Systemy Komputerowe) at the Warsaw University of Technology.

## Overview
This project involves the design and implementation of a custom **bare-metal processor system** (operating without a traditional operating system). The core objective is to integrate a specialized hardware peripheral—a custom Verilog module acting as a high-performance floating-point divider—into a 32-bit SoC architecture, complemented by a dedicated testing application and Linux kernel driver integration for comprehensive verification.

## Project Goals & Key Assumptions
- **Bare-Metal Architecture:** Build a standalone processor system that executes code directly on the hardware without the overhead of an OS layer.
- **Specialized Hardware Acceleration:** Implement a custom Verilog peripheral (`gpioemu.v`) designed to perform specialized 64-bit floating-point division operations via memory-mapped registers.
- **System Integration & Kernel Driver:** Develop a custom Linux kernel module to bridge user-space communication with the hardware peripheral utilizing a PROCFS interface (`procf s` files for arguments, control, status, and results).
- **Rigorous Testing & Verification:** Validate the system thoroughly using automated C-based test applications, ensuring precision analysis and corner-case verification against theoretical mathematical ideals.

## Architecture & Workflow
1. **Hardware Module (Verilog):** 
   - Handles 64-bit floating-point division with a custom exponent/mantissa format using state-machine logic (avoiding external libraries and loops for optimal synthesis).
   - Mapped to specific relative memory addresses for arguments, control commands, status checks, and output results.
2. **Software & Driver Layer:**
   - Exposes hardware control safely to user space through virtual files.
   - Accepts scientific notation inputs, performs validation checks, and triggers hardware calculations.
3. **Testing Suite:**
   - Automated tests verify correctness, robustness, and precision discrepancies between hardware-calculated values and mathematical ideals.

## Technologies Used
- **Verilog** (Hardware Description Language & Finite State Machines)
- **C** (Test applications and driver logic)
- **Linux Kernel Development** (PROCFS communication layer)
- **SoC Architecture & Bare-Metal Programming**
