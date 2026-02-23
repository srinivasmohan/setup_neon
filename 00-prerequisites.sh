#!/usr/bin/env bash
# 00-prerequisites.sh — Install all development tools required to build and deploy Neon on AWS EKS.
# Designed for Fedora Linux.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

log()  { echo "==> [prerequisites] $*"; }
warn() { echo "==> [prerequisites] WARNING: $*" >&2; }
die()  { echo "==> [prerequisites] FATAL: $*" >&2; exit 1; }

# ── Fedora check ──────────────────────────────────────────────────────────────
if [[ ! -f /etc/fedora-release ]]; then
    die "This script is designed for Fedora Linux. Detected: $(cat /etc/os-release 2>/dev/null | grep PRETTY_NAME || echo 'unknown')"
fi
log "Detected Fedora: $(cat /etc/fedora-release)"

# ── System packages ───────────────────────────────────────────────────────────
log "Cleaning dnf cache (avoids GPG signature verification failures)..."
sudo dnf clean all

log "Updating system packages..."
sudo dnf update -y

log "Installing build dependencies..."
sudo dnf install -y \
    readline-devel \
    zlib-devel \
    flex \
    bison \
    libxml2-devel \
    libxslt-devel \
    openssl-devel \
    libicu-devel \
    systemd-devel \
    clang-devel \
    libseccomp-devel \
    pkg-config \
    protobuf-compiler \
    protobuf-devel \
    jq \
    unzip \
    git \
    curl \
    wget

# ── Rust ──────────────────────────────────────────────────────────────────────
if command -v rustc &>/dev/null; then
    log "Rust already installed: $(rustc --version)"
else
    log "Installing Rust via rustup..."
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
    # shellcheck source=/dev/null
    source "$HOME/.cargo/env"
    log "Rust installed: $(rustc --version)"
fi

# ── Docker ────────────────────────────────────────────────────────────────────
if command -v docker &>/dev/null; then
    log "Docker already installed: $(docker --version)"
else
    log "Installing Docker..."
    sudo dnf install -y dnf-plugins-core
    sudo dnf config-manager addrepo --from-repofile=https://download.docker.com/linux/fedora/docker-ce.repo
    sudo dnf install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin
    log "Docker installed: $(docker --version)"
fi

# Start and enable Docker
if ! systemctl is-active --quiet docker; then
    log "Starting Docker service..."
    sudo systemctl start docker
    sudo systemctl enable docker
fi

# Add user to docker group (takes effect on next login)
if ! groups "$USER" | grep -q '\bdocker\b'; then
    log "Adding $USER to docker group (re-login required for group to take effect)..."
    sudo usermod -aG docker "$USER"
fi

# ── AWS CLI v2 ────────────────────────────────────────────────────────────────
if command -v aws &>/dev/null; then
    log "AWS CLI already installed: $(aws --version)"
else
    log "Installing AWS CLI v2..."
    AWSCLI_TMP="$(mktemp -d)"
    curl -s "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "${AWSCLI_TMP}/awscliv2.zip"
    unzip -q "${AWSCLI_TMP}/awscliv2.zip" -d "${AWSCLI_TMP}"
    sudo "${AWSCLI_TMP}/aws/install"
    rm -rf "${AWSCLI_TMP}"
    log "AWS CLI installed: $(aws --version)"
fi

# ── kubectl ───────────────────────────────────────────────────────────────────
if command -v kubectl &>/dev/null; then
    log "kubectl already installed: $(kubectl version --client --short 2>/dev/null || kubectl version --client)"
else
    log "Installing kubectl..."
    KUBECTL_VERSION=$(curl -L -s https://dl.k8s.io/release/stable.txt)
    curl -sLO "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl"
    chmod +x kubectl
    sudo mv kubectl /usr/local/bin/
    log "kubectl installed: $(kubectl version --client --short 2>/dev/null || kubectl version --client)"
fi

# ── eksctl ────────────────────────────────────────────────────────────────────
if command -v eksctl &>/dev/null; then
    log "eksctl already installed: $(eksctl version)"
else
    log "Installing eksctl..."
    PLATFORM="$(uname -s)_amd64"
    curl -sLO "https://github.com/eksctl-io/eksctl/releases/latest/download/eksctl_${PLATFORM}.tar.gz"
    tar -xzf "eksctl_${PLATFORM}.tar.gz" -C /tmp
    sudo mv /tmp/eksctl /usr/local/bin
    rm -f "eksctl_${PLATFORM}.tar.gz"
    log "eksctl installed: $(eksctl version)"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
log ""
log "All prerequisites installed. Verification:"
log "  Rust:    $(rustc --version 2>/dev/null || echo 'NOT FOUND')"
log "  Cargo:   $(cargo --version 2>/dev/null || echo 'NOT FOUND')"
log "  Docker:  $(docker --version 2>/dev/null || echo 'NOT FOUND')"
log "  AWS CLI: $(aws --version 2>/dev/null || echo 'NOT FOUND')"
log "  kubectl: $(kubectl version --client --short 2>/dev/null || kubectl version --client 2>/dev/null || echo 'NOT FOUND')"
log "  eksctl:  $(eksctl version 2>/dev/null || echo 'NOT FOUND')"
log "  jq:      $(jq --version 2>/dev/null || echo 'NOT FOUND')"
log ""
if ! groups "$USER" | grep -q '\bdocker\b'; then
    warn "You may need to log out and back in for the docker group to take effect."
fi
log "Done."
