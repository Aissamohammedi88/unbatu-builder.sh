# unbatu-builder.sh
# Build une distribution Linux IA-focused bootable (ISO + Live USB + disk install) # à partir de Alpine minirootfs + kernel pré-compilé + Ollama + llama.cpp + qwen2.5:1.5b # # 100% user-space : utilise proot (chroot sans root), xorriso (ISO sans root), # mksquashfs (image sans root), busybox static pour initramfs.
<div align="center">
  <h1>🧠 nexOS — The AI-Focused Linux Distribution</h1>
  <p><strong>Bootable. Portable. 100% User-Space. Zero Root Required.</strong></p>
  
  [![Alpine](https://img.shields.io/badge/Base-Alpine_Linux-0D597F?style=for-the-badge&logo=alpinelinux&logoColor=white)](#)
  [![Ollama](https://img.shields.io/badge/AI-Ollama_|_llama.cpp-00ff9d?style=for-the-badge)](#)
  [![Rootless](https://img.shields.io/badge/Sudo-Not_Required-red?style=for-the-badge)](#)
  [![License](https://img.shields.io/badge/License-MIT-blue?style=for-the-badge)](#)
</div>

---

## 🧬 Overview

**nexOS** is a specialized, bootable Linux distribution built from scratch for one purpose: **Running AI models locally, anywhere, without permission.**

Unlike traditional distributions (Ubuntu, Debian, Fedora) that require root access (`sudo`), hundreds of packages, and a massive disk footprint, nexOS is engineered to be built and run entirely in **user-space**.

**The nexOS Philosophy:**
- **Zero Root:** Uses `proot` (chroot without root) to assemble the system.
- **Zero Bloat:** Based on Alpine Linux minirootfs (a few megabytes) instead of a gigabyte-heavy base.
- **AI-First:** Ships natively with `Ollama`, `llama.cpp`, and the `qwen2.5:1.5b` model pre-configured.

---

## ⚙️ Architecture & Features

nexOS is not built like a standard OS. It is assembled using a series of user-space tools to bypass the need for administrator privileges.

```mermaid
graph TD
    A[Alpine minirootfs] --> B[proot: Isolated Environment]
    C[Pre-compiled Kernel] --> B
    D[Busybox Static] --> E[Initramfs]
    
    B --> F[Ollama + llama.cpp]
    B --> G[Qwen 2.5 1.5b Model]
    
    E --> H{mksquashfs}
    F --> H
    G --> H
    
    H -->|Image read-only| I[xorriso]
    I --> J((ISO Bootable))
    J --> K[Live USB]
    J --> L[Disk Install]
    
    style J fill:#00ff9d,color:#000,stroke:#000,stroke-width:2px
