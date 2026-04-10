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

# Verificar AWS CLI
command -v aws &>/dev/null || fail "AWS CLI no encontrado. Instálalo antes de continuar."

# Verificar Docker
command -v docker &>/dev/null || fail "Docker no encontrado. Instala Docker Desktop antes de continuar."

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

# Validar variables obligatorias
[ -z "$AWS_ACCESS_KEY_ID" ]     && fail "AWS_ACCESS_KEY_ID no definido en .env"
[ -z "$AWS_SECRET_ACCESS_KEY" ] && fail "AWS_SECRET_ACCESS_KEY no definido en .env"
[ -z "$AWS_REGION" ]            && fail "AWS_REGION no definido en .env"
[ -z "$THING_NAME" ]            && fail "THING_NAME no definido en .env"

log "Usando región: $AWS_REGION | Thing: $THING_NAME"

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
# 3. Crear directorio de certificados
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
# 11. Levantar el contenedor
# ------------------------------------------------------------
log "Iniciando contenedor Greengrass..."
docker compose down -v 2>/dev/null || true
docker compose up --build -d

log "============================================================"
log "Setup completado exitosamente."
log "Verifica mensajes en AWS IoT Console:"
log "  Region: $AWS_REGION"
log "  Test -> MQTT Test Client -> Suscribirse a: hello/world"
log "============================================================"
