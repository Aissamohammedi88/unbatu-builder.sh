#!/usr/bin/env bash
# ══════════════════════════════════════════════════════════════════════════════
# UNBATU LINUX v1.0 — Distro builder user-space, ZERO sudo
# Auteur : Aissa Mohammedi (DGK) — Nexus Quantum
#
# Build une distribution Linux IA-focused bootable (ISO + Live USB + disk install)
# à partir de Alpine minirootfs + kernel pré-compilé + Ollama + llama.cpp + qwen2.5:1.5b
#
# 100% user-space : utilise proot (chroot sans root), xorriso (ISO sans root),
# mksquashfs (image sans root), busybox static pour initramfs.
# Aucune commande sudo, aucune commande apt-get install, aucun root requis.
#
# Phases :
#   1. Vérif outils hôtes (proot, xorriso, mksquashfs, curl, etc.)
#   2. Download base (Alpine minirootfs 3MB + linux-virt kernel + busybox static)
#   3. Extraction rootfs + setup /etc (os-release, hostname, fstab, motd, profile)
#   4. Install packages via proot+apk (busybox-extras, openrc, curl, ca, nano, htop)
#   5. Bundle IA : Ollama binary + llama.cpp binary + ubnatux.sh wrapper
#   6. Pull qwen2.5:1.5b dans rootfs (mode offline si modèle déjà local)
#   7. Init script custom (mount /proc /sys /dev, mount squashfs, exec /sbin/init)
#   8. Initramfs busybox (cpio gzip)
#   9. Squashfs du rootfs complet
#  10. ISO bootable (xorriso + isolinux/syslinux)
#  11. Image Live USB (dd-able, partition FAT32 + ext4)
#  12. Installateur disque (partition + format + copy + grub)
#  13. Manifest + checksums SHA256 + build log
#  14. Menu interactif 12 choix
# ══════════════════════════════════════════════════════════════════════════════
set -uo pipefail

# ─── Couleurs ────────────────────────────────────────────────────────────────
GREEN='\033[0;32m'; YELLOW='\033[0;33m'; RED='\033[0;31m'
BLUE='\033[0;34m';  CYAN='\033[0;36m';  MAG='\033[0;35m'; B='\033[1m'; NC='\033[0m'

info()    { echo -e "${GREEN}[OK]${NC} $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
fail()    { echo -e "${RED}[ERR]${NC} $*"; }
die()     { fail "$*"; exit 1; }
section() { echo -e "\n${BLUE}===== $* =====${NC}"; }
title()   { echo -e "\n${MAG}--- $* ---${NC}"; }
hr()      { echo -e "${BLUE}────────────────────────────────────────────────${NC}"; }

# ─── Config globale ──────────────────────────────────────────────────────────
UNBATU_NAME="Unbatu Linux"
UNBATU_VERSION="1.0"
UNBATU_CODENAME="nexus"
UNBATU_AUTHOR="Aissa Mohammedi (DGK) — Nexus Quantum"
UNBATU_BANNER="UNBATU LINUX v${UNBATU_VERSION} — IA-focused distro"

# Architecture
case "$(uname -m)" in
    x86_64)  ARCH="x86_64"; ALPINE_ARCH="x86_64"; OLLAMA_ARCH="amd64"; LLAMA_ARCH="linux-amd64" ;;
    aarch64) ARCH="aarch64"; ALPINE_ARCH="aarch64"; OLLAMA_ARCH="arm64"; LLAMA_ARCH="linux-arm64" ;;
    *) die "Arch non supportée : $(uname -m)" ;;
esac

# Versions externes
ALPINE_VERSION="3.20"
ALPINE_RELEASE="3.20.3"
ALPINE_MIRROR="https://dl-cdn.alpinelinux.org/alpine"
ALPINE_ROOTFS="${ALPINE_MIRROR}/v${ALPINE_VERSION}/releases/${ALPINE_ARCH}/alpine-minirootfs-${ALPINE_RELEASE}-${ALPINE_ARCH}.tar.gz"
ALPINE_VIRT_ISO="${ALPINE_MIRROR}/v${ALPINE_VERSION}/releases/${ALPINE_ARCH}/alpine-virt-${ALPINE_RELEASE}-${ALPINE_ARCH}.iso"

OLLAMA_URL="https://ollama.com/download/ollama-linux-${OLLAMA_ARCH}"
LLAMA_RELEASE_API="https://api.github.com/repos/ggml-org/llama.cpp/releases/latest"
BUSYBOX_URL="https://busybox.net/downloads/binaries/1.36.1-defconfig-multiarch-musl/busybox-${ARCH}"
SYSLINUX_URL="https://kernel.org/pub/linux/utils/boot/syslinux/syslinux-6.03.tar.xz"

DEFAULT_MODEL="qwen2.5:1.5b"

# Dossiers (100% user-space)
BUILD_DIR="${HOME}/unbatu-build"
DL_DIR="${BUILD_DIR}/downloads"
ROOTFS="${BUILD_DIR}/rootfs"
WORK_DIR="${BUILD_DIR}/work"
ISO_DIR="${BUILD_DIR}/iso"
OUT_DIR="${BUILD_DIR}/out"
LOG_DIR="${BUILD_DIR}/logs"
BIN_DIR="${HOME}/.local/bin"

mkdir -p "$BUILD_DIR" "$DL_DIR" "$ROOTFS" "$WORK_DIR" "$ISO_DIR" "$OUT_DIR" "$LOG_DIR" "$BIN_DIR"

# Fichiers artefacts
ARTIFACT_KERNEL="${OUT_DIR}/vmlinuz-unbatu"
ARTIFACT_INITRAMFS="${OUT_DIR}/initramfs-unbatu.img"
ARTIFACT_SQUASHFS="${OUT_DIR}/rootfs-unbatu.squashfs"
ARTIFACT_ISO="${OUT_DIR}/unbatu-linux-${UNBATU_VERSION}-${ARCH}.iso"
ARTIFACT_USB="${OUT_DIR}/unbatu-linux-${UNBATU_VERSION}-${ARCH}.usb.img"
ARTIFACT_MANIFEST="${OUT_DIR}/manifest.txt"
ARTIFACT_CHECKSUMS="${OUT_DIR}/sha256sums.txt"
ARTIFACT_BUILDLOG="${LOG_DIR}/build-$(date +%Y%m%d-%H%M%S).log"

# ─── Log : tout est tee dans le build log ─────────────────────────────────────
exec > >(tee -a "$ARTIFACT_BUILDLOG") 2>&1

# ─── 1. Détection outils hôtes ───────────────────────────────────────────────
HOST_TOOLS_REQUIRED=(curl tar gzip xz unzip)
HOST_TOOLS_BUILD=(proot xorriso mksquashfs cpio find)
HOST_TOOLS_OPTIONAL=(qemu-img mkfs.vfat mkfs.ext4 parted grub-install)

check_host() {
    section "1. VÉRIFICATION OUTILS HÔTE"
    local miss=0
    echo "Requis (build minimum) :"
    for t in "${HOST_TOOLS_REQUIRED[@]}"; do
        if command -v "$t" &>/dev/null; then
            info "  $t : $(command -v "$t")"
        else
            fail "  $t : MANQUANT"
            miss=$((miss+1))
        fi
    done
    echo "Build (rootfs/ISO) :"
    for t in "${HOST_TOOLS_BUILD[@]}"; do
        if command -v "$t" &>/dev/null; then
            info "  $t : OK"
        else
            warn "  $t : absent (fonctionnalité réduite)"
        fi
    done
    echo "Optionnel (USB/disk install) :"
    for t in "${HOST_TOOLS_OPTIONAL[@]}"; do
        command -v "$t" &>/dev/null && info "  $t : OK" || warn "  $t : absent"
    done
    if (( miss > 0 )); then
        die "$miss outil(s) requis manquant(s). Installe-les (sans sudo si possible : proot via conda, xorriso via appimage, etc.)"
    fi
    info "Hôte OK pour build"
}

# ─── 2. Téléchargements (avec cache) ─────────────────────────────────────────
download_cached() {
    local url="$1" dest="$2" name="$3"
    if [[ -f "$dest" ]] && [[ -s "$dest" ]]; then
        info "Cache : $name ($dest $(du -h "$dest" | cut -f1))"
        return 0
    fi
    if [[ "${OFFLINE:-0}" == "1" ]]; then
        warn "Offline — skip $name"
        return 1
    fi
    info "Téléchargement : $name"
    info "  URL : $url"
    if curl -L -f --progress-bar "$url" -o "$dest"; then
        info "  OK : $(du -h "$dest" | cut -f1)"
        return 0
    else
        fail "  Échec download $name"
        return 1
    fi
}

download_base() {
    section "2. TÉLÉCHARGEMENTS BASE"
    download_cached "$ALPINE_ROOTFS" "${DL_DIR}/alpine-rootfs.tar.gz" "Alpine minirootfs ${ALPINE_RELEASE}" \
        || die "Alpine rootfs requis"
    download_cached "$BUSYBOX_URL" "${DL_DIR}/busybox-static" "Busybox static ${ARCH}" \
        || warn "Busybox static absent — initramfs réduit"
    chmod +x "${DL_DIR}/busybox-static" 2>/dev/null || true
    # Kernel : on extrait depuis l'ISO Alpine virt plutôt que de build
    if [[ ! -f "${DL_DIR}/vmlinuz-virt" ]]; then
        if [[ "${OFFLINE:-0}" != "1" ]]; then
            download_cached "$ALPINE_VIRT_ISO" "${DL_DIR}/alpine-virt.iso" "Alpine virt ISO (kernel source)" \
                || warn "Alpine virt ISO absent — kernel à fournir manuellement"
            if [[ -f "${DL_DIR}/alpine-virt.iso" ]]; then
                info "Extraction kernel + initramfs depuis ISO Alpine virt..."
                mkdir -p "${WORK_DIR}/virt-iso"
                xorriso -osirrox -on_disk_path -extract / "${WORK_DIR}/virt-iso" \
                    -indev "${DL_DIR}/alpine-virt.iso" >/dev/null 2>&1 || \
                    7z x -o"${WORK_DIR}/virt-iso" "${DL_DIR}/alpine-virt.iso" >/dev/null 2>&1 || \
                    warn "Extraction ISO échouée — kernel manquant"
                # Chercher vmlinuz + initramfs dans l'ISO
                find "${WORK_DIR}/virt-iso" -name 'vmlinuz*' -exec cp {} "${DL_DIR}/vmlinuz-virt" \; 2>/dev/null
                find "${WORK_DIR}/virt-iso" -name 'initramfs*' -exec cp {} "${DL_DIR}/initramfs-virt" \; 2>/dev/null
                find "${WORK_DIR}/virt-iso" -name 'modloop*' -exec cp {} "${DL_DIR}/modloop-virt" \; 2>/dev/null
                [[ -f "${DL_DIR}/vmlinuz-virt" ]] && info "Kernel extrait : ${DL_DIR}/vmlinuz-virt" \
                    || warn "vmlinuz-virt non trouvé dans ISO"
            fi
        else
            warn "Offline — kernel à fournir dans ${DL_DIR}/vmlinuz-virt"
        fi
    fi
}

# ─── 3. Extraction rootfs + setup /etc ──────────────────────────────────────
extract_rootfs() {
    section "3. EXTRACTION ROOTFS"
    if [[ -f "${ROOTFS}/etc/os-release" ]] && grep -q "Unbatu" "${ROOTFS}/etc/os-release" 2>/dev/null; then
        info "Rootfs déjà extrait — skip"
        return
    fi
    info "Extraction Alpine minirootfs vers ${ROOTFS}..."
    # Nettoyer rootfs existant partiel
    rm -rf "${ROOTFS:?}/"*
    tar xzf "${DL_DIR}/alpine-rootfs.tar.gz" -C "$ROOTFS"
    info "Rootfs extrait : $(du -sh "$ROOTFS" | cut -f1)"
}

setup_etc() {
    section "SETUP /etc"
    mkdir -p "${ROOTFS}/etc" "${ROOTFS}/etc/profile.d" "${ROOTFS}/etc/init.d" \
             "${ROOTFS}/home/nexus" "${ROOTFS}/root"
    # /etc/os-release
    cat > "${ROOTFS}/etc/os-release" << EOF
NAME="${UNBATU_NAME}"
VERSION="${UNBATU_VERSION}"
ID=unbatu
ID_LIKE=alpine
VERSION_ID="${UNBATU_VERSION}"
PRETTY_NAME="${UNBATU_NAME} ${UNBATU_VERSION} (${ARCH})"
ANSI_COLOR="1;35"
HOME_URL="https://nexus-quantum.local/unbatu"
BUG_REPORT_URL="https://nexus-quantum.local/unbatu/issues"
EOF
    info "/etc/os-release écrit"

    # /etc/hostname
    echo "unbatu" > "${ROOTFS}/etc/hostname"
    info "/etc/hostname = unbatu"

    # /etc/hosts
    cat > "${ROOTFS}/etc/hosts" << 'EOF'
127.0.0.1   localhost unbatu
::1         localhost ip6-localhost
EOF

    # /etc/fstab (pour live boot)
    cat > "${ROOTFS}/etc/fstab" << 'EOF'
# Unbatu Linux fstab (live mode)
proc        /proc      proc     defaults             0 0
sysfs       /sys       sysfs    defaults             0 0
devtmpfs    /dev       devtmpfs defaults             0 0
tmpfs       /tmp       tmpfs    defaults,size=512M   0 0
tmpfs       /run       tmpfs    defaults,size=128M   0 0
EOF

    # /etc/motd
    cat > "${ROOTFS}/etc/motd" << 'EOF'

   _   _  _   _  ___   _   ___ ___ ___
  | | | || \\ | |/ __| /_\\ | _ \\ __/ __|
  | |_| ||  `| | (__ / _ \\|   / _|\\__ \\
   \\___/ |_|\\_|_|\\___/_/ \\_\\_|_\\___|___/

   IA-focused Linux distribution  •  Nexus Quantum
   Ollama + llama.cpp pre-installed  •  qwen2.5:1.5b ready
   Type 'ubnatux --menu' to start.

EOF

    # /etc/profile.d/ai.sh
    mkdir -p "${ROOTFS}/etc/profile.d"
    cat > "${ROOTFS}/etc/profile.d/ai.sh" << 'EOF'
# Unbatu Linux AI environment
export OLLAMA_MODELS=/usr/local/share/ollama/models
export UBNATUX_HOME=/usr/local/ubnatux
export PATH="$PATH:/usr/local/bin:/usr/local/ubnatux"
alias ai='ubnatux --menu'
alias chat='ollama run qwen2.5:1.5b'
alias models='ollama list'
EOF
    chmod +x "${ROOTFS}/etc/profile.d/ai.sh"
    info "/etc/profile.d/ai.sh écrit"

    # /etc/shadow + passwd (root sans mot de passe en live)
    if ! grep -q '^root:' "${ROOTFS}/etc/passwd" 2>/dev/null; then
        echo "root::0:0:root:/root:/bin/sh" > "${ROOTFS}/etc/passwd"
    fi
    if ! grep -q '^nexus:' "${ROOTFS}/etc/passwd" 2>/dev/null; then
        echo "nexus::1000:1000:Nexus:/home/nexus:/bin/sh" >> "${ROOTFS}/etc/passwd"
        echo "nexus:*:1000:1000::/home/nexus:/bin/sh" >> "${ROOTFS}/etc/shadow"
        mkdir -p "${ROOTFS}/home/nexus"
    fi

    # /etc/resolv.conf
    cat > "${ROOTFS}/etc/resolv.conf" << 'EOF'
nameserver 1.1.1.1
nameserver 8.8.8.8
EOF

    # /etc/init.d/ai : service OpenRC qui démarre Ollama au boot
    mkdir -p "${ROOTFS}/etc/init.d"
    cat > "${ROOTFS}/etc/init.d/ai" << 'EOF'
#!/sbin/openrc-run
description="Unbatu AI services (Ollama)"
command="/usr/local/bin/ollama"
command_args="serve"
command_background=true
pidfile="/run/ollama.pid"
output_log="/var/log/ollama.log"
error_log="/var/log/ollama.err"

depend() {
    need net
    after firewall
}
EOF
    chmod +x "${ROOTFS}/etc/init.d/ai"

    info "/etc configuré (os-release, hostname, fstab, motd, profile.d/ai.sh, init.d/ai)"
}

# ─── 4. Install packages via proot ──────────────────────────────────────────
install_packages_proot() {
    section "4. INSTALL PACKAGES (proot)"
    if ! command -v proot &>/dev/null; then
        warn "proot absent — packages système non installés"
        warn "Le rootfs garde sa config Alpine minirootfs minimale"
        warn "Pour proot sans sudo : conda install proot, ou build from source"
        return 0
    fi
    info "Configuration apk repositories dans rootfs..."
    mkdir -p "${ROOTFS}/etc/apk"
    cat > "${ROOTFS}/etc/apk/repositories" << EOF
${ALPINE_MIRROR}/v${ALPINE_VERSION}/main
${ALPINE_MIRROR}/v${ALPINE_VERSION}/community
EOF

    info "Installation packages via proot (peut prendre 5-10 min)..."
    local pkgs="busybox-extras openrc curl ca-certificates nano htop less "
    pkgs+="openssh iproute2 iptables wireless-tools wpa_supplicant "
    pkgs+="bash bash-completion tzdata"

    # proot : chroot user-space
    proot --rootfs="$ROOTFS" \
          --root-id --link2symlink \
          --cwd=/root \
          /sbin/apk update 2>&1 | tail -3 || warn "apk update échoué"
    proot --rootfs="$ROOTFS" \
          --root-id --link2symlink \
          --cwd=/root \
          /sbin/apk add $pkgs 2>&1 | tail -5 || warn "apk add échoué"

    # Activer services au boot
    proot --rootfs="$ROOTFS" --root-id --link2symlink \
          /sbin/rc-update add ai default 2>/dev/null || warn "rc-update ai échoué"
    proot --rootfs="$ROOTFS" --root-id --link2symlink \
          /sbin/rc-update add networking boot 2>/dev/null || true
    proot --rootfs="$ROOTFS" --root-id --link2symlink \
          /sbin/rc-update add sshd default 2>/dev/null || true

    info "Packages installés via proot"
}

# ─── 5. Bundle IA : Ollama + llama.cpp + ubnatux ────────────────────────────
install_ollama_in_rootfs() {
    section "5. BUNDLE IA — Ollama"
    local ol_dest="${ROOTFS}/usr/local/bin/ollama"
    mkdir -p "${ROOTFS}/usr/local/bin"
    if [[ -f "$ol_dest" ]] && [[ -x "$ol_dest" ]]; then
        info "Ollama déjà présent dans rootfs"
        return
    fi
    if [[ ! -f "${DL_DIR}/ollama-binary" ]]; then
        download_cached "$OLLAMA_URL" "${DL_DIR}/ollama-binary" "Ollama binary ${OLLAMA_ARCH}" \
            || { warn "Ollama non téléchargé — distro sans Ollama"; return; }
    fi
    cp "${DL_DIR}/ollama-binary" "$ol_dest"
    chmod +x "$ol_dest"
    info "Ollama installé dans rootfs : /usr/local/bin/ollama"

    # Dossier modèles partagé
    mkdir -p "${ROOTFS}/usr/local/share/ollama/models"
    # Service : déjà créé dans setup_etc (/etc/init.d/ai)
}

install_llamacpp_in_rootfs() {
    section "BUNDLE IA — llama.cpp"
    local ll_dir="${ROOTFS}/usr/local/llamacpp"
    local cli_dest="${ll_dir}/llama-cli"
    if [[ -x "$cli_dest" ]]; then
        info "llama.cpp déjà présent dans rootfs"
        return
    fi
    mkdir -p "$ll_dir"
    # Try pre-built binary
    if [[ ! -f "${DL_DIR}/llama-cli" ]]; then
        info "Recherche release llama.cpp..."
        local latest
        latest=$(curl -fsSL "$LLAMA_RELEASE_API" 2>/dev/null \
            | grep -oE '"tag_name":\s*"[^"]+"' | head -1 | cut -d'"' -f4)
        [[ -z "$latest" ]] && latest="master"
        info "Latest release : $latest"
        local urls=(
            "https://github.com/ggml-org/llama.cpp/releases/download/${latest}/llama-${LLAMA_ARCH}.zip"
            "https://github.com/ggml-org/llama.cpp/releases/download/${latest}/llama-${LLAMA_ARCH}-cuda.zip"
        )
        for url in "${urls[@]}"; do
            if curl -L -f "$url" -o /tmp/llama-unbatux.zip 2>/dev/null; then
                unzip -o /tmp/llama-unbatux.zip -d "${DL_DIR}/llama-extract" >/dev/null 2>&1
                find "${DL_DIR}/llama-extract" -name 'llama-cli' -type f -executable \
                    -exec cp {} "${DL_DIR}/llama-cli" \; 2>/dev/null
                find "${DL_DIR}/llama-extract" -name 'llama-server' -type f -executable \
                    -exec cp {} "${DL_DIR}/llama-server" \; 2>/dev/null
                [[ -f "${DL_DIR}/llama-cli" ]] && break
            fi
        done
    fi
    if [[ -f "${DL_DIR}/llama-cli" ]]; then
        cp "${DL_DIR}/llama-cli" "$cli_dest"
        chmod +x "$cli_dest"
        [[ -f "${DL_DIR}/llama-server" ]] && cp "${DL_DIR}/llama-server" "${ll_dir}/llama-server"
        info "llama-cli installé dans rootfs : $cli_dest"
    else
        warn "llama.cpp pre-built non disponible — fallback build from source"
        warn "Sur la distro, installe cmake+g++ puis : cd /tmp && git clone https://github.com/ggml-org/llama.cpp && cmake -B build && cmake --build build"
    fi
}

install_ubnatux_wrapper() {
    section "BUNDLE IA — ubnatux wrapper"
    local ub_dest="${ROOTFS}/usr/local/bin/ubnatux"
    local ub_home="${ROOTFS}/usr/local/ubnatux"
    mkdir -p "$ub_home" "${ROOTFS}/usr/local/bin"

    # Si ubnatux.sh existe déjà livré (v3.0), l'embarquer
    if [[ -f "${HOME}/.local/bin/ubnatux" ]] && [[ -x "${HOME}/.local/bin/ubnatux" ]]; then
        info "Embarquement ubnatux depuis ~/.local/bin/ubnatux"
        cp "${HOME}/.local/bin/ubnatux" "$ub_dest"
    elif [[ -f "${BUILD_DIR}/ubnatux.sh" ]]; then
        info "Embarquement ubnatux depuis ${BUILD_DIR}/ubnatux.sh"
        cp "${BUILD_DIR}/ubnatux.sh" "$ub_dest"
    else
        info "ubnatux externe non trouvé — écriture version minimale inline"
        cat > "$ub_dest" << 'WRAPPER'
#!/usr/bin/env bash
# ubnatux minimal wrapper (embarqué dans Unbatu Linux)
set -uo pipefail
GREEN='\033[0;32m'; YELLOW='\033[0;33m'; RED='\033[0;31m'; CYAN='\033[0;36m'; NC='\033[0m'
info() { echo -e "${GREEN}[OK]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
fail() { echo -e "${RED}[ERR]${NC} $*"; }
DEFAULT_MODEL="qwen2.5:1.5b"
case "${1:-}" in
    --menu)
        while true; do
            echo -e "\n${CYAN}--- UBNATUX MENU (minimal) ---${NC}"
            echo "  1) Lister modèles"
            echo "  2) Run modèle"
            echo "  3) Pull modèle"
            echo "  4) Statut"
            echo "  5) Quitter"
            read -rp "> " c
            case "$c" in
                1) ollama list ;;
                2) read -rp "Modèle [$DEFAULT_MODEL] : " m; m="${m:-$DEFAULT_MODEL}"
                   read -rp "Prompt : " p; ollama run "$m" "$p" ;;
                3) read -rp "Modèle à pull [$DEFAULT_MODEL] : " m; ollama pull "${m:-$DEFAULT_MODEL}" ;;
                4) command -v ollama && ollama list || fail "ollama absent" ;;
                5) break ;;
            esac
        done ;;
    --status)
        command -v ollama && ollama list || fail "ollama absent"
        [[ -x /usr/local/llamacpp/llama-cli ]] && info "llama.cpp OK" || warn "llama.cpp absent"
        ;;
    "")
        echo "Usage: ubnatux [--menu|--status|<model> <prompt>]"; exit 1 ;;
    *)
        ollama run "$@" ;;
esac
WRAPPER
    fi
    chmod +x "$ub_dest"
    info "ubnatux wrapper installé : /usr/local/bin/ubnatux"

    # Liens symboliques utiles
    ln -sf /usr/local/bin/ubnatux "${ROOTFS}/usr/local/bin/ai" 2>/dev/null || true
}

pull_default_model() {
    section "PULL MODÈLE PAR DÉFAUT"
    local models_dir="${ROOTFS}/usr/local/share/ollama/models"
    mkdir -p "$models_dir"
    # Si déjà présent dans le HOME de l'hôte, copier
    local host_models="${HOME}/.ollama/models"
    if [[ -d "$host_models" ]] && [[ -n "$(ls -A "$host_models" 2>/dev/null)" ]]; then
        info "Copie modèles depuis $host_models..."
        cp -rn "$host_models"/* "$models_dir"/ 2>/dev/null || warn "Copie partielle"
        info "Modèles copiés : $(du -sh "$models_dir" | cut -f1)"
        return
    fi
    # Sinon, pull via proot+ollama
    if command -v proot &>/dev/null && [[ -x "${ROOTFS}/usr/local/bin/ollama" ]]; then
        info "Pull ${DEFAULT_MODEL} dans rootfs via proot (peut prendre qq min)..."
        proot --rootfs="$ROOTFS" --root-id --link2symlink \
              /usr/local/bin/ollama serve >/dev/null 2>&1 &
        local pid=$!
        sleep 3
        proot --rootfs="$ROOTFS" --root-id --link2symlink \
              /usr/local/bin/ollama pull "$DEFAULT_MODEL" 2>&1 | tail -5 \
            || warn "Pull échoué (modèle sera pull au premier boot)"
        kill "$pid" 2>/dev/null || true
        info "Modèle pull (si succès)"
    else
        warn "proot/ollama absent — pull sera fait au premier boot de la distro"
        warn "Le service /etc/init.d/ai démarrera ollama, et /etc/profile.d/ai.sh affichera l'aide"
    fi
}

bundle_ai_full() {
    install_ollama_in_rootfs
    install_llamacpp_in_rootfs
    install_ubnatux_wrapper
    pull_default_model
}

# ─── 6. Init script custom (pour initramfs) ──────────────────────────────────
write_init_script() {
    section "6. INIT SCRIPT CUSTOM (initramfs)"
    local init_dest="${WORK_DIR}/init"
    cat > "$init_dest" << 'INIT'
#!/bin/sh
# Unbatu Linux init (initramfs)
# Monte les fs nécessaires, charge le rootfs squashfs, pivot_root vers /sbin/init

PATH=/bin:/sbin:/usr/bin:/usr/sbin
export PATH

# 1. Mount kernel filesystems
mount -t proc none /proc 2>/dev/null
mount -t sysfs none /sys 2>/dev/null
mount -t devtmpfs none /dev 2>/dev/null || mdev -s

# 2. Load modules essentiels (depuis modloop si présent)
for mod in squashfs overlay loop vfat ext4; do
    modprobe "$mod" 2>/dev/null
done

# 3. Paramètres kernel (cmdline)
CMDLINE=$(cat /proc/cmdline 2>/dev/null)
UNBATU_LIVE=1
UNBATU_ROOT=""
for arg in $CMDLINE; do
    case "$arg" in
        unbatu.live=0)   UNBATU_LIVE=0 ;;
        unbatu.root=*)   UNBATU_ROOT="${arg#unbatu.root=}" ;;
        root=*)          UNBATU_ROOT="${arg#root=}" ;;
    esac
done

# 4. Trouver le squashfs rootfs (sur tout device avec label UNBATU)
find_squashfs() {
    for dev in /dev/sd* /dev/nvme* /dev/vd* /dev/mmcblk*; do
        [ -b "$dev" ] || continue
        for part in "${dev}"1 "${dev}"2 "${dev}"p1 "${dev}"p2 "${dev}"; do
            [ -b "$part" ] || continue
            mkdir -p /mnt/try 2>/dev/null
            mount "$part" /mnt/try 2>/dev/null || continue
            if [ -f /mnt/try/boot/rootfs-unbatu.squashfs ]; then
                echo "/mnt/try/boot/rootfs-unbatu.squashfs"
                return
            elif [ -f /mnt/try/rootfs-unbatu.squashfs ]; then
                echo "/mnt/try/rootfs-unbatu.squashfs"
                return
            fi
            umount /mnt/try 2>/dev/null
        done
    done
    return 1
}

# 5. Mode live : mount squashfs + overlay
if [ "$UNBATU_LIVE" = "1" ]; then
    SQUASHFS=$(find_squashfs)
    if [ -z "$SQUASHFS" ]; then
        echo "[UNBATU] rootfs-unbatu.squashfs non trouvé — drop to shell"
        exec /bin/sh
    fi
    echo "[UNBATU] Mounting $SQUASHFS..."
    mkdir -p /ro /rw /overlay /newroot
    mount -t squashfs -o ro "$(dirname "$SQUASHFS")/$(basename "$SQUASHFS")" /ro 2>/dev/null \
        || mount -o loop,ro "$SQUASHFS" /ro
    mount -t tmpfs none /rw
    mkdir -p /rw/upper /rw/work
    mount -t overlay overlay -o lowerdir=/ro,upperdir=/rw/upper,workdir=/rw/work /newroot
else
    # Mode installé : root= sur disque
    [ -z "$UNBATU_ROOT" ] && UNBATU_ROOT="/dev/sda1"
    echo "[UNBATU] Mounting root $UNBATU_ROOT..."
    mount "$UNBATU_ROOT" /newroot 2>/dev/null || mount -o ro "$UNBATU_ROOT" /newroot
fi

# 6. Pivot_root vers /newroot et exec /sbin/init
if [ -x /newroot/sbin/init ]; then
    mount --move /proc /newroot/proc 2>/dev/null
    mount --move /sys  /newroot/sys  2>/dev/null
    mount --move /dev  /newroot/dev  2>/dev/null
    cd /newroot
    exec /sbin/init
else
    echo "[UNBATU] /sbin/init manquant dans rootfs — drop to shell"
    exec /bin/sh
fi
INIT
    chmod +x "$init_dest"
    info "Init script custom écrit : ${init_dest}"
}

# ─── 7. Initramfs build (busybox + init) ─────────────────────────────────────
build_initramfs() {
    section "7. INITRAMFS BUILD"
    local initramfs_work="${WORK_DIR}/initramfs"
    mkdir -p "$initramfs_work"/{bin,sbin,proc,sys,dev,mnt,ro,rw,overlay,newroot,lib}

    # Init script
    cp "${WORK_DIR}/init" "${initramfs_work}/init"
    chmod +x "${initramfs_work}/init"

    # Busybox static
    if [[ -f "${DL_DIR}/busybox-static" ]] && [[ -x "${DL_DIR}/busybox-static" ]]; then
        cp "${DL_DIR}/busybox-static" "${initramfs_work}/bin/busybox"
        info "Busybox static intégré"
    else
        warn "Busybox static absent — initramfs utilise /bin/sh de l'hôte (risque cassure)"
        cp /bin/sh "${initramfs_work}/bin/sh" 2>/dev/null || die "/bin/sh requis"
    fi

    # Liens busybox vers les commandes essentielles
    local cmds="sh mount umount mkdir cat echo ls modprobe mdev find pivot_root switch_root"
    cmds+=" sleep grep cut dirname basename test [ switch_root"
    for cmd in $cmds; do
        ln -sf busybox "${initramfs_work}/bin/$cmd" 2>/dev/null
    done

    # Création du device console
    mknod "${initramfs_work}/dev/console" c 5 1 2>/dev/null || warn "mknod console échoué (normal sans root)"
    mknod "${initramfs_work}/dev/null"    c 1 3 2>/dev/null || true

    # Pack cpio + gzip
    info "Packing initramfs..."
    (
        cd "$initramfs_work"
        find . -print0 | cpio --null -ov --format=newc 2>/dev/null \
            | gzip -9 > "$ARTIFACT_INITRAMFS"
    )
    [[ -f "$ARTIFACT_INITRAMFS" ]] \
        && info "Initramfs créé : $(du -h "$ARTIFACT_INITRAMFS" | cut -f1)" \
        || die "Initramfs build échoué"
}

# ─── 8. Squashfs du rootfs complet ──────────────────────────────────────────
build_squashfs() {
    section "8. SQUASHFS ROOTFS"
    if ! command -v mksquashfs &>/dev/null; then
        warn "mksquashfs absent — rootfs laissé en tarball"
        tar czf "${OUT_DIR}/rootfs-unbatu.tar.gz" -C "$BUILD_DIR" rootfs
        info "Tarball rootfs : $(du -h "${OUT_DIR}/rootfs-unbatu.tar.gz" | cut -f1)"
        return
    fi
    if [[ -f "$ARTIFACT_SQUASHFS" ]] && [[ -s "$ARTIFACT_SQUASHFS" ]]; then
        info "Squashfs existe déjà — rebuild? (supprime pour forcer)"
        return
    fi
    info "Création squashfs (peut prendre 2-5 min)..."
    # -comp zstd pour meilleure compression, -no-xattrs pour clean
    mksquashfs "$ROOTFS" "$ARTIFACT_SQUASHFS" \
        -comp zstd -Xcompression-level 19 -no-xattrs -noappend \
        2>&1 | tail -3 || \
    mksquashfs "$ROOTFS" "$ARTIFACT_SQUASHFS" -comp gzip -no-xattrs -noappend 2>&1 | tail -3
    [[ -f "$ARTIFACT_SQUASHFS" ]] \
        && info "Squashfs créé : $(du -h "$ARTIFACT_SQUASHFS" | cut -f1)" \
        || die "Squashfs build échoué"
}

# ─── 9. Préparation kernel ──────────────────────────────────────────────────
prepare_kernel() {
    section "9. KERNEL"
    if [[ -f "${DL_DIR}/vmlinuz-virt" ]]; then
        cp "${DL_DIR}/vmlinuz-virt" "$ARTIFACT_KERNEL"
        info "Kernel : $(du -h "$ARTIFACT_KERNEL" | cut -f1)"
        # Modloop si extrait (modules kernel)
        if [[ -f "${DL_DIR}/modloop-virt" ]]; then
            cp "${DL_DIR}/modloop-virt" "${OUT_DIR}/modloop-unbatu"
            info "Modloop : $(du -h "${OUT_DIR}/modloop-unbatu" | cut -f1)"
        fi
    elif [[ -f "/boot/vmlinuz-$(uname -r)" ]]; then
        warn "Utilisation du kernel hôte (à éviter si possible)"
        cp "/boot/vmlinuz-$(uname -r)" "$ARTIFACT_KERNEL"
    else
        die "Aucun kernel disponible — fournis-le dans ${DL_DIR}/vmlinuz-virt"
    fi
}

# ─── 10. ISO bootable (xorriso + isolinux) ──────────────────────────────────
build_iso() {
    section "10. ISO BOOTABLE"
    command -v xorriso &>/dev/null || die "xorriso requis pour ISO"
    mkdir -p "${ISO_DIR}/boot/isolinux"

    # Copier kernel + initramfs + squashfs dans l'ISO
    cp "$ARTIFACT_KERNEL"     "${ISO_DIR}/boot/vmlinuz"
    cp "$ARTIFACT_INITRAMFS"  "${ISO_DIR}/boot/initramfs.img"
    cp "$ARTIFACT_SQUASHFS"   "${ISO_DIR}/boot/rootfs-unbatu.squashfs"
    [[ -f "${OUT_DIR}/modloop-unbatu" ]] && cp "${OUT_DIR}/modloop-unbatu" "${ISO_DIR}/boot/modloop"

    # Isolinux/syslinux : d'abord chercher sur l'hôte
    local isolinux_bin="" ldlinux_c32=""
    for p in /usr/lib/syslinux/isolinux.bin \
             /usr/lib/ISOLINUX/isolinux.bin \
             /usr/share/syslinux/isolinux.bin \
             /usr/share/ISOLINUX/isolinux.bin; do
        [[ -f "$p" ]] && isolinux_bin="$p" && break
    done
    for p in /usr/lib/syslinux/ldlinux.c32 \
             /usr/share/syslinux/ldlinux.c32; do
        [[ -f "$p" ]] && ldlinux_c32="$p" && break
    done

    if [[ -z "$isolinux_bin" ]]; then
        # Télécharger syslinux
        info "isolinux absent sur hôte — download syslinux 6.03..."
        if [[ ! -f "${DL_DIR}/syslinux.tar.xz" ]]; then
            curl -L -f "$SYSLINUX_URL" -o "${DL_DIR}/syslinux.tar.xz" 2>/dev/null \
                || die "Téléchargement syslinux échoué"
        fi
        mkdir -p "${WORK_DIR}/syslinux"
        tar xJf "${DL_DIR}/syslinux.tar.xz" -C "${WORK_DIR}/syslinux" 2>/dev/null
        isolinux_bin=$(find "${WORK_DIR}/syslinux" -name 'isolinux.bin' | head -1)
        ldlinux_c32=$(find "${WORK_DIR}/syslinux" -name 'ldlinux.c32' | head -1)
    fi

    if [[ -z "$isolinux_bin" ]] || [[ ! -f "$isolinux_bin" ]]; then
        die "isolinux.bin introuvable — installe syslinux sur l'hôte"
    fi
    cp "$isolinux_bin" "${ISO_DIR}/boot/isolinux/isolinux.bin"
    [[ -n "$ldlinux_c32" ]] && [[ -f "$ldlinux_c32" ]] \
        && cp "$ldlinux_c32" "${ISO_DIR}/boot/isolinux/ldlinux.c32"

    # Config isolinux.cfg
    cat > "${ISO_DIR}/boot/isolinux/isolinux.cfg" << EOF
DEFAULT unbatu
PROMPT 0
TIMEOUT 30
LABEL unbatu
    MENU LABEL ${UNBATU_BANNER}
    KERNEL /boot/vmlinuz
    APPEND initrd=/boot/initramfs.img unbatu.live=1 console=tty0 console=ttyS0,115200 quiet
LABEL unbatu-debug
    MENU LABEL ${UNBATU_BANNER} (debug)
    KERNEL /boot/vmlinuz
    APPEND initrd=/boot/initramfs.img unbatu.live=1 console=tty0 loglevel=7
LABEL unbatu-shell
    MENU LABEL ${UNBATU_BANNER} (rescue shell)
    KERNEL /boot/vmlinuz
    APPEND initrd=/boot/initramfs.img unbatu.live=0 init=/bin/sh
EOF

    # Menu UI si menu.c32 dispo
    for p in /usr/lib/syslinux/menu.c32 /usr/share/syslinux/menu.c32; do
        [[ -f "$p" ]] && cp "$p" "${ISO_DIR}/boot/isolinux/" && \
            sed -i '1i UI menu.c32' "${ISO_DIR}/boot/isolinux/isolinux.cfg" && break
    done

    # Volume ID
    local volid="UNBATU_${UNBATU_VERSION}"

    # Build ISO
    info "Build ISO avec xorriso..."
    xorriso -as mkisofs \
        -volid "$volid" \
        -isohybrid-mbr "${ISO_DIR}/boot/isolinux/isolinux.bin" \
        -eltorito-boot boot/isolinux/isolinux.bin \
        -boot-load-size 4 -boot-info-table -no-emul-boot \
        -eltorito-catalog boot/isolinux/boot.cat \
        -isohybrid-gpt-basdat \
        -appid "${UNBATU_NAME} ${UNBATU_VERSION}" \
        -publisher "${UNBATU_AUTHOR}" \
        -preparer "Unbatu builder" \
        -V "$volid" \
        -r -J -joliet-long \
        -o "$ARTIFACT_ISO" \
        "$ISO_DIR" 2>&1 | tail -5

    if [[ -f "$ARTIFACT_ISO" ]]; then
        info "ISO créé : $ARTIFACT_ISO ($(du -h "$ARTIFACT_ISO" | cut -f1))"
    else
        die "ISO build échoué"
    fi
}

# ─── 11. Live USB image (dd-able) ───────────────────────────────────────────
build_usb_image() {
    section "11. LIVE USB IMAGE"
    command -v qemu-img &>/dev/null || { warn "qemu-img absent — skip image USB"; return 1; }
    local size_mb="${1:-2048}"
    info "Création image USB ${size_mb} MB..."

    # Créer image raw
    qemu-img create -f raw "$ARTIFACT_USB" "${size_mb}M" >/dev/null

    # Si parted + mkfs disponibles, partitionner
    if command -v parted &>/dev/null; then
        parted -s "$ARTIFACT_USB" mklabel msdos \
            mkpart primary fat32 1MiB 200MiB \
            mkpart primary ext4 200MiB 100% \
            set 1 boot on 2>&1 | tail -3
        info "Partitions : 1 FAT32 (boot) + 2 ext4 (rootfs persistent)"
    else
        warn "parted absent — image non partitionnée (raw dd ISO à la place)"
        cp "$ARTIFACT_ISO" "$ARTIFACT_USB"
        return 0
    fi

    # Note : pour formatter les partitions, on doit utiliser des tools qui supportent
    # les images disque sans device-mapper. mtools (mkfs.vfat -i) et mkfs.ext4 -E
    # off_device peuvent le faire user-space.
    warn "Formatage partitions — non automatisé (utilise losetup+mkfs après dd, ou mtools)"
    warn "Pour usage simple : dd if=$ARTIFACT_ISO of=/dev/sdX bs=4M status=progress"
    info "Image USB créée : $ARTIFACT_USB ($(du -h "$ARTIFACT_USB" | cut -f1))"
}

# ─── 12. Installateur disque ────────────────────────────────────────────────
disk_install() {
    section "12. INSTALLATEUR DISQUE"
    local target="${1:-}"
    [[ -z "$target" ]] && die "Usage : unbatu-builder.sh --install /dev/sdX"
    [[ -b "$target" ]] || die "$target n'est pas un block device"

    warn "WARNING : va écraser $target — confirmation requise"
    read -rp "Type 'WIPE' pour confirmer : " confirm
    [[ "$confirm" == "WIPE" ]] || die "Annulé"

    info "Partitionnement $target..."
    parted -s "$target" mklabel msdos \
        mkpart primary ext4 1MiB 100% \
        set 1 boot on

    local part="${target}1"
    [[ "$target" =~ nvme ]] && part="${target}p1"

    info "Formatage $part ext4..."
    mkfs.ext4 -F "$part"

    info "Montage et copy rootfs..."
    local mnt="/mnt/unbatu-install"
    mkdir -p "$mnt"
    mount "$part" "$mnt" 2>/dev/null \
        || die "mount $part échoué — lance ce script en root pour --install (sudo externe, pas dans le script)"

    info "Copy rootfs..."
    cp -a "$ROOTFS"/* "$mnt"/
    info "Copy kernel + initramfs..."
    mkdir -p "$mnt/boot"
    cp "$ARTIFACT_KERNEL"    "$mnt/boot/vmlinuz"
    cp "$ARTIFACT_INITRAMFS" "$mnt/boot/initramfs.img"

    info "Install GRUB..."
    if command -v grub-install &>/dev/null; then
        grub-install --root-directory="$mnt" "$target" 2>&1 | tail -3
        cat > "$mnt/boot/grub/grub.cfg" << EOF
default=0
timeout=5
title ${UNBATU_BANNER}
    root (hd0,1)
    kernel /boot/vmlinuz root=${part} rw quiet
    initrd /boot/initramfs.img
EOF
    else
        warn "grub-install absent — extlinux installé à la place"
        extlinux --install "$mnt/boot" 2>/dev/null
    fi

    umount "$mnt" 2>/dev/null
    info "Install terminé sur $target"
    info "Reboot sur le disque pour démarrer Unbatu Linux"
}

# ─── 13. Manifest + checksums ───────────────────────────────────────────────
generate_manifest() {
    section "MANIFEST + CHECKSUMS"
    {
        echo "=== ${UNBATU_NAME} ${UNBATU_VERSION} ==="
        echo "Date build : $(date -Iseconds)"
        echo "Builder    : ${UNBATU_AUTHOR}"
        echo "Arch       : ${ARCH}"
        echo "Base       : Alpine ${ALPINE_RELEASE} minirootfs"
        echo ""
        echo "--- Artefacts ---"
        for f in "$ARTIFACT_KERNEL" "$ARTIFACT_INITRAMFS" "$ARTIFACT_SQUASHFS" \
                 "$ARTIFACT_ISO" "$ARTIFACT_USB" "$OUT_DIR/modloop-unbatu"; do
            [[ -f "$f" ]] && echo "$(du -h "$f" | cut -f1)  $(basename "$f")"
        done
        echo ""
        echo "--- Rootfs ---"
        echo "Taille rootfs décompressé : $(du -sh "$ROOTFS" | cut -f1)"
        echo "Fichiers : $(find "$ROOTFS" -type f | wc -l)"
        echo ""
        echo "--- Bundle IA ---"
        [[ -x "${ROOTFS}/usr/local/bin/ollama" ]] && \
            echo "Ollama : $(file "${ROOTFS}/usr/local/bin/ollama" | cut -d: -f2)"
        [[ -x "${ROOTFS}/usr/local/llamacpp/llama-cli" ]] && \
            echo "llama.cpp : $(file "${ROOTFS}/usr/local/llamacpp/llama-cli" | cut -d: -f2)"
        [[ -x "${ROOTFS}/usr/local/bin/ubnatux" ]] && \
            echo "ubnatux wrapper : OK"
        echo "Modèle par défaut : ${DEFAULT_MODEL}"
        echo ""
        echo "--- Config ---"
        cat "${ROOTFS}/etc/os-release"
    } > "$ARTIFACT_MANIFEST"
    info "Manifest : $ARTIFACT_MANIFEST"

    # SHA256 checksums
    {
        echo "# ${UNBATU_NAME} ${UNBATU_VERSION} — SHA256"
        cd "$OUT_DIR"
        for f in vmlinuz-unbatu initramfs-unbatu.img rootfs-unbatu.squashfs \
                 unbatu-linux-${UNBATU_VERSION}-${ARCH}.iso \
                 unbatu-linux-${UNBATU_VERSION}-${ARCH}.usb.img; do
            [[ -f "$f" ]] && sha256sum "$f"
        done
    } > "$ARTIFACT_CHECKSUMS"
    info "Checksums : $ARTIFACT_CHECKSUMS"
}

# ─── 14. Statut ──────────────────────────────────────────────────────────────
status_report() {
    title "STATUT ${UNBATU_NAME} v${UNBATU_VERSION}"
    echo -e "  ${B}Distro${NC}     : ${CYAN}${UNBATU_NAME} ${UNBATU_VERSION} (${ARCH})${NC}"
    echo -e "  ${B}Base${NC}       : Alpine ${ALPINE_RELEASE} minirootfs"
    echo -e "  ${B}Bundle IA${NC}  : Ollama + llama.cpp + ubnatux + ${DEFAULT_MODEL}"
    echo -e "  ${B}Build dir${NC}  : ${BUILD_DIR}"
    echo -e "  ${B}Output dir${NC} : ${OUT_DIR}"
    echo ""
    echo "Artefacts :"
    for f in "$ARTIFACT_KERNEL" "$ARTIFACT_INITRAMFS" "$ARTIFACT_SQUASHFS" \
             "$ARTIFACT_ISO" "$ARTIFACT_USB" "$ARTIFACT_MANIFEST" "$ARTIFACT_CHECKSUMS"; do
        if [[ -f "$f" ]]; then
            echo -e "  ${GREEN}OK${NC}  $(du -h "$f" | cut -f1)  $(basename "$f")"
        else
            echo -e "  ${YELLOW}--${NC}  non buildé  $(basename "$f")"
        fi
    done
    echo ""
    echo "Rootfs :"
    if [[ -d "$ROOTFS" ]] && [[ -n "$(ls -A "$ROOTFS" 2>/dev/null)" ]]; then
        echo -e "  ${GREEN}OK${NC}  $(du -sh "$ROOTFS" | cut -f1)  $(find "$ROOTFS" -type f | wc -l) fichiers"
    else
        echo -e "  ${YELLOW}--${NC}  non extrait"
    fi
    echo ""
    echo "Outils hôtes :"
    for t in proot xorriso mksquashfs cpio qemu-img parted; do
        command -v "$t" &>/dev/null \
            && echo -e "  ${GREEN}OK${NC}  $t" \
            || echo -e "  ${YELLOW}--${NC}  $t absent"
    done
    echo ""
    echo "Build logs : ${LOG_DIR}"
}

# ─── 15. Menu interactif ────────────────────────────────────────────────────
menu() {
    while true; do
        title "${UNBATU_BANNER} — MENU"
        echo "  1)  Vérif outils hôtes"
        echo "  2)  Télécharger base (Alpine + kernel + busybox)"
        echo "  3)  Extraire rootfs"
        echo "  4)  Setup /etc"
        echo "  5)  Install packages (proot)"
        echo "  6)  Bundle IA (Ollama + llama.cpp + ubnatux)"
        echo "  7)  Pull modèle par défaut"
        echo "  8)  Build initramfs"
        echo "  9)  Build squashfs"
        echo "  10) Build ISO bootable"
        echo "  11) Build Live USB image"
        echo "  12) Manifest + checksums"
        echo "  13) BUILD FULL (1→12)"
        echo "  14) Statut"
        echo "  15) Clean (rm rootfs + work)"
        echo "  16) Quitter"
        echo
        read -rp "Choix > " c
        case "$c" in
            1)  check_host ;;
            2)  download_base ;;
            3)  extract_rootfs ;;
            4)  setup_etc ;;
            5)  install_packages_proot ;;
            6)  bundle_ai_full ;;
            7)  pull_default_model ;;
            8)  write_init_script; build_initramfs ;;
            9)  build_squashfs ;;
            10) prepare_kernel; build_iso ;;
            11) build_usb_image ;;
            12) generate_manifest ;;
            13) build_full ;;
            14) status_report ;;
            15) read -rp "Confirme clean? [y/N] : " cc; [[ "$cc" == "y" ]] && clean_work ;;
            16) info "Au revoir"; break ;;
            *)  warn "Choix invalide" ;;
        esac
    done
}

clean_work() {
    section "CLEAN"
    rm -rf "${WORK_DIR:?}/"*
    rm -rf "${ROOTFS:?}/"*
    info "Work + rootfs nettoyés (downloads conservés)"
}

# ─── 16. Build full (chaîne complète) ───────────────────────────────────────
build_full() {
    section "BUILD FULL ${UNBATU_NAME} v${UNBATU_VERSION}"
    info "Début : $(date -Iseconds)"
    info "Build dir : $BUILD_DIR"

    check_host
    download_base
    extract_rootfs
    setup_etc
    install_packages_proot
    bundle_ai_full
    write_init_script
    build_initramfs
    build_squashfs
    prepare_kernel
    build_iso
    build_usb_image
    generate_manifest

    section "RAPPORT FINAL"
    echo -e "  ${B}Distro${NC}      : ${CYAN}${UNBATU_NAME} v${UNBATU_VERSION}${NC}"
    echo -e "  ${B}Artefacts${NC}   :"
    for f in "$ARTIFACT_KERNEL" "$ARTIFACT_INITRAMFS" "$ARTIFACT_SQUASHFS" \
             "$ARTIFACT_ISO" "$ARTIFACT_USB" "$ARTIFACT_MANIFEST" "$ARTIFACT_CHECKSUMS"; do
        [[ -f "$f" ]] && echo -e "    $(du -h "$f" | cut -f1)  $(basename "$f")"
    done
    echo -e "  ${B}ISO${NC}         : $ARTIFACT_ISO"
    echo -e "  ${B}Flash USB${NC}   : dd if=$ARTIFACT_ISO of=/dev/sdX bs=4M status=progress"
    echo -e "  ${B}Test QEMU${NC}   : qemu-system-x86_64 -m 2G -cdrom $ARTIFACT_ISO -boot d"
    echo -e "  ${B}Manifest${NC}    : $ARTIFACT_MANIFEST"
    echo -e "  ${B}Checksums${NC}   : $ARTIFACT_CHECKSUMS"
    echo -e "  ${B}Build log${NC}   : $ARTIFACT_BUILDLOG"
    echo ""
    info "Build terminé : $(date -Iseconds)"
}

# ─── 17. Aide ────────────────────────────────────────────────────────────────
usage() {
    cat << EOF
${UNBATU_BANNER}
${UNBATU_AUTHOR}

Usage :
  unbatu-builder.sh [commande]

Commandes :
  --build-full         Build complet (download -> ISO -> USB -> manifest)
  --check-host         Vérifie outils hôtes (proot, xorriso, mksquashfs, ...)
  --download           Télécharge base (Alpine rootfs + kernel + busybox)
  --rootfs             Extrait + setup /etc (os-release, hostname, fstab, motd, profile)
  --packages           Install packages via proot (busybox-extras, openrc, curl, ...)
  --bundle-ai          Bundle IA (Ollama + llama.cpp + ubnatux wrapper)
  --pull-model         Pull ${DEFAULT_MODEL} dans rootfs
  --initramfs          Build initramfs custom (busybox + init script)
  --squashfs           Build squashfs du rootfs
  --iso                Build ISO bootable (xorriso + isolinux)
  --usb [size_mb]      Build Live USB image (default 2048 MB)
  --manifest           Génère manifest + checksums SHA256
  --install /dev/sdX   Installe sur disque (DANGEREUX — WIPE demandé)
  --status             Statut build actuel (artefacts, rootfs, outils)
  --menu               Menu interactif 16 choix
  --clean              Nettoie work + rootfs (garde downloads)
  --help               Cette aide

Additif :
  - ZERO sudo dans le script (proot pour chroot user-space)
  - Cache downloads dans ${DL_DIR}
  - Build log tee dans ${ARTIFACT_BUILDLOG}
  - Si offline, saute downloads et utilise cache

Examples :
  unbatu-builder.sh --build-full
  unbatu-builder.sh --menu
  unbatu-builder.sh --check-host
  unbatu-builder.sh --iso

Output dir : ${OUT_DIR}
Build dir  : ${BUILD_DIR}
EOF
}

# ─── Point d'entrée ──────────────────────────────────────────────────────────
main() {
    section "${UNBATU_BANNER}"
    info "Auteur : ${UNBATU_AUTHOR}"
    info "Arch   : ${ARCH}  Base : Alpine ${ALPINE_RELEASE}"
    info "Build  : ${BUILD_DIR}"
    info "Output : ${OUT_DIR}"

    case "${1:-}" in
        --build-full)    build_full ;;
        --check-host)    check_host ;;
        --download)      download_base ;;
        --rootfs)        extract_rootfs; setup_etc ;;
        --packages)      install_packages_proot ;;
        --bundle-ai)     bundle_ai_full ;;
        --pull-model)    pull_default_model ;;
        --initramfs)     write_init_script; build_initramfs ;;
        --squashfs)      build_squashfs ;;
        --iso)           prepare_kernel; build_iso ;;
        --usb)           shift; build_usb_image "$@" ;;
        --manifest)      generate_manifest ;;
        --install)       shift; disk_install "$@" ;;
        --status)        status_report ;;
        --menu)          menu ;;
        --clean)         clean_work ;;
        --help|-h)       usage ;;
        --offline)       OFFLINE=1; shift; main "$@" ;;
        "")              menu ;;
        *)
            warn "Commande inconnue : $1"
            usage
            exit 1
            ;;
    esac
}

main "$@"
