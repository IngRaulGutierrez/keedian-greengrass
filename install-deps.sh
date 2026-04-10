#!/bin/bash

# ============================================================
# install-deps.sh — Instala AWS CLI, Docker Desktop y Python 3
# Compatible con Linux, macOS y Windows (Git Bash / MSYS2)
# ============================================================
# Uso: bash install-deps.sh
# ============================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log()   { echo -e "${GREEN}[deps]${NC} $1"; }
warn()  { echo -e "${YELLOW}[deps]${NC} $1"; }
info()  { echo -e "${BLUE}[deps]${NC} $1"; }
fail()  { echo -e "${RED}[error]${NC} $1"; exit 1; }
ok()    { echo -e "${GREEN}[deps]${NC} ✓ $1"; }
skip()  { echo -e "${YELLOW}[deps]${NC} → $1 ya instalado. Omitiendo."; }

RESTART_REQUIRED=false
MANUAL_STEPS=()

# ------------------------------------------------------------
# Detectar OS
# ------------------------------------------------------------
OS_TYPE=$(uname -s)
case "$OS_TYPE" in
    Linux*)             OS=Linux ;;
    Darwin*)            OS=macOS ;;
    MINGW*|MSYS*|CYGWIN*) OS=Windows ;;
    *)                  fail "Sistema operativo no soportado: $OS_TYPE" ;;
esac
log "Sistema operativo: $OS"

# ------------------------------------------------------------
# Funciones por plataforma
# ------------------------------------------------------------

# --- WINDOWS -------------------------------------------------

win_run_ps() {
    # Ejecuta un comando PowerShell desde Git Bash
    powershell.exe -NoProfile -NonInteractive -Command "$1"
}

win_winget_install() {
    local id="$1"
    local name="$2"
    log "Instalando $name via winget..."
    win_run_ps "winget install --id $id --accept-source-agreements --accept-package-agreements --silent" \
        || warn "winget reportó un error instalando $name (puede ser que ya esté instalado o requiera reinicio)"
}

install_python_windows() {
    if command -v python3 &>/dev/null || command -v python &>/dev/null; then
        ver=$(python3 --version 2>/dev/null || python --version 2>/dev/null)
        skip "Python ($ver)"
        return
    fi
    win_winget_install "Python.Python.3.12" "Python 3.12"
    RESTART_REQUIRED=true
    MANUAL_STEPS+=("Reinicia Git Bash para que Python quede disponible en el PATH.")
    ok "Python instalado."
}

install_awscli_windows() {
    if command -v aws &>/dev/null; then
        skip "AWS CLI ($(aws --version 2>&1 | head -1))"
        return
    fi
    log "Instalando AWS CLI v2..."
    TMP_MSI=$(mktemp --suffix=.msi 2>/dev/null || echo "/tmp/awscliv2_$$.msi")
    # Descargar con PowerShell (no depende de curl)
    win_run_ps "
        \$ProgressPreference = 'SilentlyContinue'
        Invoke-WebRequest -Uri 'https://awscli.amazonaws.com/AWSCLIV2.msi' -OutFile '$(cygpath -w "$TMP_MSI" 2>/dev/null || echo "$TMP_MSI")'
    " || fail "No se pudo descargar AWS CLI. Verifica tu conexión a internet."
    win_run_ps "Start-Process msiexec.exe -Wait -ArgumentList '/i', '$(cygpath -w "$TMP_MSI" 2>/dev/null || echo "$TMP_MSI")', '/quiet', '/norestart'"
    rm -f "$TMP_MSI"
    RESTART_REQUIRED=true
    MANUAL_STEPS+=("Reinicia Git Bash para que AWS CLI quede disponible en el PATH.")
    ok "AWS CLI instalado."
}

install_docker_windows() {
    if command -v docker &>/dev/null && docker info &>/dev/null 2>&1; then
        skip "Docker ($(docker --version))"
        return
    fi
    if command -v docker &>/dev/null; then
        warn "Docker está instalado pero no está corriendo. Abre Docker Desktop manualmente."
        MANUAL_STEPS+=("Abre Docker Desktop y espera a que el daemon arranque antes de ejecutar setup.sh.")
        return
    fi

    # Verificar WSL2 (requerido por Docker Desktop en Windows)
    log "Verificando WSL2..."
    WSL_STATUS=$(win_run_ps "wsl --status 2>&1" 2>/dev/null || echo "")
    if ! win_run_ps "wsl -l -v 2>&1" | grep -q "2" 2>/dev/null; then
        warn "WSL2 puede no estar habilitado. Habilitando..."
        win_run_ps "wsl --install --no-distribution" 2>/dev/null || true
        RESTART_REQUIRED=true
        MANUAL_STEPS+=("IMPORTANTE: Reinicia Windows para completar la instalación de WSL2, luego ejecuta este script de nuevo.")
    fi

    win_winget_install "Docker.DockerDesktop" "Docker Desktop"
    RESTART_REQUIRED=true
    MANUAL_STEPS+=("Reinicia Windows si se solicitó, luego abre Docker Desktop y espera a que arranque.")
    MANUAL_STEPS+=("En Docker Desktop: Settings → General → activa 'Use WSL 2 based engine'.")
    ok "Docker Desktop instalado."
}

# --- macOS ---------------------------------------------------

install_homebrew_macos() {
    if command -v brew &>/dev/null; then
        return
    fi
    log "Instalando Homebrew..."
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" \
        || fail "No se pudo instalar Homebrew."
    # Agregar brew al PATH para esta sesión
    if [ -f "/opt/homebrew/bin/brew" ]; then
        eval "$(/opt/homebrew/bin/brew shellenv)"
    elif [ -f "/usr/local/bin/brew" ]; then
        eval "$(/usr/local/bin/brew shellenv)"
    fi
    ok "Homebrew instalado."
}

install_python_macos() {
    if command -v python3 &>/dev/null; then
        skip "Python ($(python3 --version))"
        return
    fi
    install_homebrew_macos
    log "Instalando Python 3..."
    brew install python3
    ok "Python 3 instalado."
}

install_awscli_macos() {
    if command -v aws &>/dev/null; then
        skip "AWS CLI ($(aws --version 2>&1 | head -1))"
        return
    fi
    install_homebrew_macos
    log "Instalando AWS CLI..."
    brew install awscli
    ok "AWS CLI instalado."
}

install_docker_macos() {
    if command -v docker &>/dev/null && docker info &>/dev/null 2>&1; then
        skip "Docker ($(docker --version))"
        return
    fi
    if command -v docker &>/dev/null; then
        warn "Docker está instalado pero no está corriendo. Abre Docker Desktop."
        MANUAL_STEPS+=("Abre Docker Desktop desde Aplicaciones y espera a que el daemon arranque.")
        return
    fi
    install_homebrew_macos
    log "Instalando Docker Desktop..."
    brew install --cask docker
    MANUAL_STEPS+=("Abre Docker Desktop desde Aplicaciones y espera a que el daemon arranque antes de ejecutar setup.sh.")
    ok "Docker Desktop instalado."
}

# --- Linux ---------------------------------------------------

detect_linux_pm() {
    if command -v apt-get &>/dev/null; then echo "apt"
    elif command -v dnf &>/dev/null;     then echo "dnf"
    elif command -v yum &>/dev/null;     then echo "yum"
    else echo "unknown"
    fi
}

install_python_linux() {
    if command -v python3 &>/dev/null; then
        skip "Python ($(python3 --version))"
        return
    fi
    PM=$(detect_linux_pm)
    log "Instalando Python 3 ($PM)..."
    case "$PM" in
        apt) sudo apt-get update -qq && sudo apt-get install -y python3 python3-pip ;;
        dnf) sudo dnf install -y python3 python3-pip ;;
        yum) sudo yum install -y python3 python3-pip ;;
        *)   fail "Gestor de paquetes no soportado. Instala Python 3 manualmente." ;;
    esac
    ok "Python 3 instalado."
}

install_awscli_linux() {
    if command -v aws &>/dev/null; then
        skip "AWS CLI ($(aws --version 2>&1 | head -1))"
        return
    fi
    log "Instalando AWS CLI v2..."
    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64)  URL="https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" ;;
        aarch64) URL="https://awscli.amazonaws.com/awscli-exe-linux-aarch64.zip" ;;
        *)       fail "Arquitectura no soportada para AWS CLI: $ARCH" ;;
    esac
    TMP_DIR=$(mktemp -d)
    curl -s "$URL" -o "$TMP_DIR/awscliv2.zip"
    unzip -q "$TMP_DIR/awscliv2.zip" -d "$TMP_DIR"
    sudo "$TMP_DIR/aws/install" --update
    rm -rf "$TMP_DIR"
    ok "AWS CLI instalado."
}

install_docker_linux() {
    if command -v docker &>/dev/null && docker info &>/dev/null 2>&1; then
        skip "Docker ($(docker --version))"
        return
    fi
    PM=$(detect_linux_pm)
    log "Instalando Docker ($PM)..."
    case "$PM" in
        apt)
            sudo apt-get update -qq
            sudo apt-get install -y docker.io
            sudo systemctl start docker
            sudo systemctl enable docker
            ;;
        dnf)
            sudo dnf install -y docker
            sudo systemctl start docker
            sudo systemctl enable docker
            ;;
        yum)
            sudo yum install -y docker
            sudo systemctl start docker
            sudo systemctl enable docker
            ;;
        *)
            fail "Gestor de paquetes no soportado. Instala Docker manualmente."
            ;;
    esac
    # Agregar usuario al grupo docker para evitar usar sudo
    if ! groups "$USER" | grep -q docker 2>/dev/null; then
        sudo usermod -aG docker "$USER"
        MANUAL_STEPS+=("Cierra sesión y vuelve a entrar (o ejecuta 'newgrp docker') para usar Docker sin sudo.")
    fi
    ok "Docker instalado."
}

# ------------------------------------------------------------
# Ejecutar instalaciones según OS
# ------------------------------------------------------------
echo ""
info "=== Verificando e instalando dependencias ==="
echo ""

case "$OS" in
    Windows)
        # Verificar que winget esté disponible
        win_run_ps "Get-Command winget -ErrorAction Stop" &>/dev/null \
            || fail "winget no encontrado. Actualiza Windows 10/11 desde Microsoft Store (App Installer)."
        install_python_windows
        install_awscli_windows
        install_docker_windows
        ;;
    macOS)
        install_python_macos
        install_awscli_macos
        install_docker_macos
        ;;
    Linux)
        install_python_linux
        install_awscli_linux
        install_docker_linux
        ;;
esac

# ------------------------------------------------------------
# Resumen final
# ------------------------------------------------------------
echo ""
info "=== Verificación final ==="

ALL_OK=true

for tool in "python3:Python" "aws:AWS CLI" "docker:Docker"; do
    cmd="${tool%%:*}"
    name="${tool##*:}"
    if command -v "$cmd" &>/dev/null; then
        ver=$("$cmd" --version 2>&1 | head -1)
        ok "$name → $ver"
    else
        warn "$name → no disponible en PATH (puede requerir reinicio de terminal)"
        ALL_OK=false
    fi
done

echo ""

if [ ${#MANUAL_STEPS[@]} -gt 0 ]; then
    warn "=== Pasos manuales requeridos ==="
    for i in "${!MANUAL_STEPS[@]}"; do
        warn "  $((i+1)). ${MANUAL_STEPS[$i]}"
    done
    echo ""
fi

if [ "$RESTART_REQUIRED" = true ]; then
    warn "Reinicia tu terminal (o Windows si se indicó) y luego ejecuta:"
    warn "  bash setup.sh"
elif [ "$ALL_OK" = true ]; then
    log "============================================================"
    log "Todas las dependencias están listas."
    log "Ahora ejecuta: bash setup.sh"
    log "============================================================"
fi
