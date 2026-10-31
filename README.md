# unbatu-builder.sh
# Build une distribution Linux IA-focused bootable (ISO + Live USB + disk install) # à partir de Alpine minirootfs + kernel pré-compilé + Ollama + llama.cpp + qwen2.5:1.5b # # 100% user-space : utilise proot (chroot sans root), xorriso (ISO sans root), # mksquashfs (image sans root), busybox static pour initramfs.
