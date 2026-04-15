#!/bin/bash
set -e

# ============================================================
# setup.sh — Configura y levanta Greengrass Hello World
# Compatible con Linux, macOS y Windows (Git Bash / MSYS2)
# ============================================================
# Uso: bash setup.sh
# Requisitos: Docker Desktop (Linux containers), AWS CLI, Python 3
# ============================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()  { echo -e "${GREEN}[setup]${NC} $1"; }
warn() { echo -e "${YELLOW}[setup]${NC} $1"; }
fail() { echo -e "${RED}[error]${NC} $1"; exit 1; }

# ------------------------------------------------------------
# 0. Detectar OS y Python
# ------------------------------------------------------------
OS_TYPE=$(uname -s)
case "$OS_TYPE" in
    Linux*)   OS=Linux ;;
    Darwin*)  OS=macOS ;;
    MINGW*|MSYS*|CYGWIN*) OS=Windows ;;
    *)        OS=Unknown ;;
esac
log "Sistema operativo detectado: $OS ($OS_TYPE)"

PYTHON=""
for cmd in python3 python; do
    if command -v "$cmd" &>/dev/null; then
        version=$("$cmd" -c "import sys; print(sys.version_info.major)" 2>/dev/null)
        if [ "$version" = "3" ]; then
            PYTHON="$cmd"
            break
        fi
    fi
done
[ -z "$PYTHON" ] && fail "Python 3 no encontrado. Instálalo antes de continuar."
log "Python detectado: $PYTHON ($($PYTHON --version 2>&1))"

# Verificar dependencias — instalar automáticamente si faltan
DEPS_MISSING=false
command -v aws    &>/dev/null || DEPS_MISSING=true
command -v docker &>/dev/null || DEPS_MISSING=true

if [ "$DEPS_MISSING" = true ]; then
    warn "Dependencias faltantes. Ejecutando install-deps.sh..."
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    bash "$SCRIPT_DIR/install-deps.sh" || fail "La instalación de dependencias falló."

    # Refrescar PATH para la sesión actual
    export PATH="$PATH:/usr/local/bin:/usr/bin"
    hash -r 2>/dev/null || true

    # Re-verificar tras la instalación
    command -v aws    &>/dev/null || fail "AWS CLI no quedó disponible. Reinicia la terminal y ejecuta setup.sh de nuevo."
    command -v docker &>/dev/null || fail "Docker no quedó disponible. Reinicia la terminal y ejecuta setup.sh de nuevo."
fi

# ------------------------------------------------------------
# Funciones Python para manejo portable del .env
# ------------------------------------------------------------

# Lee el valor de una variable del .env (maneja espacios y comillas)
get_env_var() {
    local key="$1"
    "$PYTHON" - "$key" <<'PYEOF'
import sys, re
key = sys.argv[1]
try:
    with open('.env', 'r', encoding='utf-8') as f:
        for line in f:
            line = line.rstrip('\n\r')
            if line.startswith('#') or '=' not in line:
                continue
            k, _, v = line.partition('=')
            if k.strip() == key:
                # strip surrounding quotes if present
                v = v.strip()
                if (v.startswith('"') and v.endswith('"')) or \
                   (v.startswith("'") and v.endswith("'")):
                    v = v[1:-1]
                print(v)
                sys.exit(0)
except FileNotFoundError:
    pass
PYEOF
}

# Actualiza (o agrega) una variable en el .env
update_env_var() {
    local key="$1"
    local value="$2"
    "$PYTHON" - "$key" "$value" <<'PYEOF'
import sys, re, os

key   = sys.argv[1]
value = sys.argv[2]

with open('.env', 'r', encoding='utf-8') as f:
    content = f.read()

pattern = rf'^({re.escape(key)}=).*'
replacement = rf'\g<1>{value}'

if re.search(pattern, content, flags=re.MULTILINE):
    new_content = re.sub(pattern, replacement, content, flags=re.MULTILINE)
else:
    new_content = content.rstrip('\n') + f'\n{key}={value}\n'

with open('.env', 'w', encoding='utf-8', newline='\n') as f:
    f.write(new_content)
PYEOF
}

# Verifica si un directorio existe — maneja rutas Windows (D:/...), WSL2 (/mnt/d/...) y Git Bash (/d/...)
dir_exists() {
    "$PYTHON" - "$1" <<'PYEOF'
import os, sys, re
path = sys.argv[1]
if os.path.isdir(path):
    sys.exit(0)
# Intentar traducir ruta Windows D:/... a rutas Unix equivalentes
m = re.match(r'^([A-Za-z]):[/\\](.*)', path)
if m:
    drive = m.group(1).lower()
    rest  = m.group(2).replace('\\', '/')
    for prefix in (f'/mnt/{drive}/', f'/{drive}/'):   # WSL2 y Git Bash
        if os.path.isdir(prefix + rest):
            sys.exit(0)
sys.exit(1)
PYEOF
}

# Convierte CRLF → LF en un archivo (portable, binario)
fix_crlf() {
    local filepath="$1"
    "$PYTHON" - "$filepath" <<'PYEOF'
import sys
path = sys.argv[1]
with open(path, 'rb') as f:
    content = f.read()
fixed = content.replace(b'\r\n', b'\n')
if fixed != content:
    with open(path, 'wb') as f:
        f.write(fixed)
    print(f"[setup] CRLF corregido en: {path}")
PYEOF
}

# ------------------------------------------------------------
# 1. Cargar .env
# ------------------------------------------------------------
if [ ! -f .env ]; then
    fail "Archivo .env no encontrado. Copia .env.example a .env y completa los valores."
fi

# Leer variables individualmente con Python para evitar problemas con espacios
AWS_ACCESS_KEY_ID=$(get_env_var AWS_ACCESS_KEY_ID)
AWS_SECRET_ACCESS_KEY=$(get_env_var AWS_SECRET_ACCESS_KEY)
AWS_REGION=$(get_env_var AWS_REGION)
THING_NAME=$(get_env_var THING_NAME)
DEVICE_NAME=$(get_env_var DEVICE_NAME)
KEEDIAN_LINK_COMPONENTS_PATH=$(get_env_var KEEDIAN_LINK_COMPONENTS_PATH)

# Validar variables obligatorias
[ -z "$AWS_ACCESS_KEY_ID" ]     && fail "AWS_ACCESS_KEY_ID no definido en .env"
[ -z "$AWS_SECRET_ACCESS_KEY" ] && fail "AWS_SECRET_ACCESS_KEY no definido en .env"
[ -z "$AWS_REGION" ]            && fail "AWS_REGION no definido en .env"
[ -z "$THING_NAME" ]            && fail "THING_NAME no definido en .env"

# Auto-detectar ruta de keedian-link si no está configurada
if [ -z "$KEEDIAN_LINK_COMPONENTS_PATH" ]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    AUTO_PATH="$(dirname "$SCRIPT_DIR")/keedian-link/components"
    if dir_exists "$AUTO_PATH"; then
        KEEDIAN_LINK_COMPONENTS_PATH="$AUTO_PATH"
        log "keedian-link detectado automáticamente: $KEEDIAN_LINK_COMPONENTS_PATH"
        update_env_var "KEEDIAN_LINK_COMPONENTS_PATH" "$KEEDIAN_LINK_COMPONENTS_PATH"
    else
        warn "No se detectó keedian-link automáticamente en: $AUTO_PATH"
        while true; do
            echo -n "[setup] Ingresa la ruta absoluta a la carpeta components/ de keedian-link: "
            read -r KEEDIAN_LINK_COMPONENTS_PATH
            if dir_exists "$KEEDIAN_LINK_COMPONENTS_PATH"; then
                log "Ruta válida: $KEEDIAN_LINK_COMPONENTS_PATH"
                update_env_var "KEEDIAN_LINK_COMPONENTS_PATH" "$KEEDIAN_LINK_COMPONENTS_PATH"
                break
            else
                warn "La carpeta no existe: $KEEDIAN_LINK_COMPONENTS_PATH — intenta de nuevo."
            fi
        done
    fi
fi
dir_exists "$KEEDIAN_LINK_COMPONENTS_PATH" \
    || fail "La carpeta keedian-link components no existe: $KEEDIAN_LINK_COMPONENTS_PATH"

log "Usando región: $AWS_REGION | Thing: $THING_NAME"
log "Componentes keedian-link: $KEEDIAN_LINK_COMPONENTS_PATH"

# ------------------------------------------------------------
# 2. Configurar AWS CLI con credenciales del .env
# ------------------------------------------------------------
export AWS_ACCESS_KEY_ID
export AWS_SECRET_ACCESS_KEY
export AWS_DEFAULT_REGION="$AWS_REGION"

aws sts get-caller-identity --query 'Arn' --output text > /dev/null \
    || fail "Credenciales AWS inválidas. Verifica AWS_ACCESS_KEY_ID y AWS_SECRET_ACCESS_KEY en .env"

log "Credenciales AWS verificadas."

# ------------------------------------------------------------
# 3. Adjuntar política Greengrass al Token Exchange Role
# ------------------------------------------------------------
GG_POLICY_NAME="GreengrassComponentAccess"
GG_ROLE_NAME="GreengrassV2TokenExchangeRole"

aws iam put-role-policy \
    --role-name "$GG_ROLE_NAME" \
    --policy-name "$GG_POLICY_NAME" \
    --policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Action":["greengrass:GetComponentVersionArtifact","greengrass:ResolveComponentCandidates","greengrass:GetDeploymentConfiguration","greengrass:ListThingGroupsForCoreDevice"],"Resource":"*"}]}' \
    --region "$AWS_REGION" > /dev/null 2>&1 \
    && log "Política '$GG_POLICY_NAME' adjuntada a '$GG_ROLE_NAME'." \
    || warn "No se pudo adjuntar política a '$GG_ROLE_NAME' (puede no existir o faltar permisos IAM)."

# ------------------------------------------------------------
# 4. Crear directorio de certificados
# ------------------------------------------------------------
mkdir -p config

# ------------------------------------------------------------
# 4. Crear Thing (idempotente)
# ------------------------------------------------------------
if aws iot describe-thing --thing-name "$THING_NAME" --region "$AWS_REGION" &>/dev/null; then
    warn "Thing '$THING_NAME' ya existe. Omitiendo creación."
else
    aws iot create-thing --thing-name "$THING_NAME" --region "$AWS_REGION" > /dev/null
    log "Thing '$THING_NAME' creado."
fi

# ------------------------------------------------------------
# 5. Crear certificados (solo si no existen localmente)
# ------------------------------------------------------------
if [ -f config/device.pem.crt ] && [ -f config/private.pem.key ]; then
    warn "Certificados ya existen en config/. Omitiendo creación."
    CERT_ARN=$(aws iot list-thing-principals \
        --thing-name "$THING_NAME" \
        --region "$AWS_REGION" \
        --query 'principals[0]' \
        --output text 2>/dev/null || echo "")
else
    log "Creando certificados X.509..."
    CERT_JSON=$(aws iot create-keys-and-certificate \
        --set-as-active \
        --certificate-pem-outfile "config/device.pem.crt" \
        --public-key-outfile  "config/public.pem.key" \
        --private-key-outfile "config/private.pem.key" \
        --region "$AWS_REGION")
    CERT_ARN=$(echo "$CERT_JSON" | "$PYTHON" -c "import sys,json; print(json.load(sys.stdin)['certificateArn'])")
    log "Certificado creado: $CERT_ARN"
fi

# ------------------------------------------------------------
# 6. Crear política IoT (idempotente)
# ------------------------------------------------------------
if aws iot get-policy --policy-name GreengrassDockerPolicy --region "$AWS_REGION" &>/dev/null; then
    warn "Política 'GreengrassDockerPolicy' ya existe. Omitiendo creación."
else
    aws iot create-policy \
        --policy-name GreengrassDockerPolicy \
        --policy-document file://iot-policy.json \
        --region "$AWS_REGION" > /dev/null
    log "Política 'GreengrassDockerPolicy' creada."
fi

# ------------------------------------------------------------
# 7. Adjuntar política y certificado al Thing
# ------------------------------------------------------------
if [ -n "$CERT_ARN" ] && [ "$CERT_ARN" != "None" ]; then
    aws iot attach-policy \
        --policy-name GreengrassDockerPolicy \
        --target "$CERT_ARN" \
        --region "$AWS_REGION" 2>/dev/null || true

    aws iot attach-thing-principal \
        --thing-name "$THING_NAME" \
        --principal "$CERT_ARN" \
        --region "$AWS_REGION" 2>/dev/null || true

    log "Política y certificado adjuntados al Thing."
fi

# ------------------------------------------------------------
# 8. Descargar CA raíz de Amazon (si no existe)
# ------------------------------------------------------------
if [ ! -f config/AmazonRootCA1.pem ]; then
    log "Descargando AmazonRootCA1.pem..."
    # Intentar con curl, si no con Python urllib
    if command -v curl &>/dev/null; then
        curl -s https://www.amazontrust.com/repository/AmazonRootCA1.pem \
            -o config/AmazonRootCA1.pem
    else
        "$PYTHON" -c "
import urllib.request
urllib.request.urlretrieve(
    'https://www.amazontrust.com/repository/AmazonRootCA1.pem',
    'config/AmazonRootCA1.pem'
)
"
    fi
    log "CA raíz descargada."
else
    warn "AmazonRootCA1.pem ya existe. Omitiendo descarga."
fi

# ------------------------------------------------------------
# 9. Obtener endpoints de IoT y actualizar .env
# ------------------------------------------------------------
log "Obteniendo endpoints de AWS IoT..."

DATA_ENDPOINT=$(aws iot describe-endpoint \
    --endpoint-type iot:Data-ATS \
    --region "$AWS_REGION" \
    --query endpointAddress --output text)

CRED_ENDPOINT=$(aws iot describe-endpoint \
    --endpoint-type iot:CredentialProvider \
    --region "$AWS_REGION" \
    --query endpointAddress --output text)

update_env_var "IOT_DATA_ENDPOINT" "$DATA_ENDPOINT"
update_env_var "IOT_CRED_ENDPOINT" "$CRED_ENDPOINT"

log "Endpoints configurados en .env:"
log "  Data:        $DATA_ENDPOINT"
log "  Credential:  $CRED_ENDPOINT"

# ------------------------------------------------------------
# 10. Corregir CRLF en entrypoint.sh (Windows)
# ------------------------------------------------------------
fix_crlf "greengrass-core/entrypoint.sh"
log "Saltos de línea de entrypoint.sh verificados (LF)."

# ------------------------------------------------------------
# 11. Verificar red keedian-network
# ------------------------------------------------------------
if ! docker network inspect keedian-network &>/dev/null; then
    fail "La red Docker 'keedian-network' no existe. Ejecuta primero el setup.sh del proyecto keedian-link."
fi
log "Red keedian-network verificada."

# ------------------------------------------------------------
# 12. Levantar el contenedor
# ------------------------------------------------------------
log "Iniciando contenedor Greengrass..."

# Exportar el path de componentes en el formato que Docker entiende según el contexto:
#   WSL2 (Linux):   D:/foo  →  /mnt/d/foo
#   Git Bash (Windows): D:/foo  →  D:/foo  (Docker Desktop lo traduce directamente)
KEEDIAN_LINK_COMPONENTS_PATH=$(
    "$PYTHON" - "$KEEDIAN_LINK_COMPONENTS_PATH" "$OS" <<'PYEOF'
import sys, re, os
path  = sys.argv[1]
os_id = sys.argv[2]
if os_id == 'Linux':
    m = re.match(r'^([A-Za-z]):[/\\](.*)', path)
    if m:
        drive = m.group(1).lower()
        rest  = m.group(2).replace('\\', '/')
        print(f'/mnt/{drive}/{rest}')
        sys.exit(0)
print(path)
PYEOF
)
export KEEDIAN_LINK_COMPONENTS_PATH
log "Path Docker para keedian-link: $KEEDIAN_LINK_COMPONENTS_PATH"

docker compose down -v 2>/dev/null || true
docker compose up --build -d

# ------------------------------------------------------------
# 13. Esperar que el Nucleus esté listo
# ------------------------------------------------------------
wait_nucleus_ready() {
    local timeout=180
    local elapsed=0
    log "Esperando que el Nucleus arranque (máx. ${timeout}s)..."
    while [ $elapsed -lt $timeout ]; do
        if docker logs greengrass-core 2>&1 | grep -q "Launched Nucleus successfully"; then
            log "Nucleus listo."
            return 0
        fi
        sleep 5
        elapsed=$((elapsed + 5))
        warn "  Esperando Nucleus... (${elapsed}s / ${timeout}s)"
    done
    fail "Timeout esperando el Nucleus. Revisa: docker logs greengrass-core"
}
wait_nucleus_ready

# ------------------------------------------------------------
# 14. Provisionar entorno Python en el contenedor
# ------------------------------------------------------------
provision_greengrass_container() {
    log "Verificando provisioning del contenedor..."

    # Las dependencias Python están instaladas en la imagen (Dockerfile).
    # Aquí solo verificamos y creamos gateway.yaml si falta.

    echo "[setup]   Instalando dependencias Python..."
    docker exec greengrass-core python3 -m pip install --quiet \
        structlog \
        pydantic \
        pyyaml \
        "sqlalchemy[asyncio]" \
        asyncpg \
        pymodbus \
        tenacity \
        psutil \
        python-dateutil \
        APScheduler \
        httpx \
        zstandard \
        "BAC0>=2024.9.8"
    echo "[setup]   ✓ Dependencias instaladas."

    # Crear gateway.yaml si no existe (no se genera en entrypoint.sh porque
    # necesita THING_NAME que viene del .env del host)
    if docker exec greengrass-core test -f /var/lib/keedian-gw/configs/gateway.yaml 2>/dev/null; then
        warn "  gateway.yaml ya existe. Omitiendo."
    else
        log "  Creando gateway.yaml de desarrollo..."
        THING_NAME_VAL=$(get_env_var THING_NAME)
        docker exec greengrass-core bash -c "cat > /var/lib/keedian-gw/configs/gateway.yaml << 'YAMLEOF'
gateway_id: \"${THING_NAME_VAL}\"
log_level: \"INFO\"

network:
  interfaces:
    - name: \"eth0\"
      role: \"uplink\"
      metric: 100
  fallback_to_dhcp: true

cloud:
  tuten_mqtt:
    enabled: true
    broker: \"tuten-gw-mqtt\"
    port: 1883
    client_id: \"${THING_NAME_VAL}\"
    qos: 1
    keepalive: 60
  telemetry:
    level: \"standard\"
    interval: 300
YAMLEOF"
        log "  ✓ gateway.yaml creado."
    fi

    log "Provisioning verificado."
}
provision_greengrass_container

# ------------------------------------------------------------
# 15. Esperar inicialización de componentes keedian-link
# ------------------------------------------------------------
log "Esperando inicialización de componentes (30s)..."
sleep 30

# ------------------------------------------------------------
# 16. Verificar estado de los componentes por sus logs
# ------------------------------------------------------------
COMPONENTS=(
    "com.keedian.config-manager"
    "com.keedian.db-layer"
    "com.keedian.task-manager"
    "com.keedian.modbus-adapter"
    "com.keedian.bacnet-adapter"
    "com.keedian.data-uploader"
)

log "Verificando estado de los componentes..."
ALL_OK=true
for comp in "${COMPONENTS[@]}"; do
    log_file="/greengrass/v2/logs/${comp}.log"
    if docker exec greengrass-core sh -c "test -f $log_file" 2>/dev/null; then
        if docker exec greengrass-core sh -c "grep -q FATAL $log_file" 2>/dev/null; then
            warn "  ✗ $comp → tiene errores FATAL en log"
            ALL_OK=false
        else
            log "  ✓ $comp → activo (sin errores FATAL)"
        fi
    else
        warn "  ? $comp → log no disponible aún (puede estar iniciando)"
    fi
done

if [ "$ALL_OK" = true ]; then
    log "============================================================"
    log "Setup completado. Componentes keedian-link iniciados."
    log "Para ver logs: docker exec greengrass-core tail -f /greengrass/v2/logs/<nombre>.log"
    log "============================================================"
else
    warn "============================================================"
    warn "Algunos componentes tienen errores. Revisa sus logs:"
    warn "  docker exec greengrass-core tail -100 /greengrass/v2/logs/<nombre>.log"
    warn "============================================================"
fi
