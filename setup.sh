#!/bin/bash
set -e

# ============================================================
# setup.sh — Configura y levanta Greengrass Hello World
# ============================================================
# Uso: bash setup.sh
# Requisitos: Docker Desktop (Linux containers), AWS CLI instalado
# ============================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()  { echo -e "${GREEN}[setup]${NC} $1"; }
warn() { echo -e "${YELLOW}[setup]${NC} $1"; }
fail() { echo -e "${RED}[error]${NC} $1"; exit 1; }

# ------------------------------------------------------------
# 1. Cargar .env
# ------------------------------------------------------------
if [ ! -f .env ]; then
    fail "Archivo .env no encontrado. Copia .env.example a .env y completa los valores."
fi

set -a
source .env
set +a

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
export AWS_DEFAULT_REGION=$AWS_REGION

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
    CERT_ARN=$(echo "$CERT_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin)['certificateArn'])")
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
    curl -s https://www.amazontrust.com/repository/AmazonRootCA1.pem \
        -o config/AmazonRootCA1.pem
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

sed -i "s|IOT_DATA_ENDPOINT=.*|IOT_DATA_ENDPOINT=$DATA_ENDPOINT|" .env
sed -i "s|IOT_CRED_ENDPOINT=.*|IOT_CRED_ENDPOINT=$CRED_ENDPOINT|" .env

log "Endpoints configurados en .env:"
log "  Data:        $DATA_ENDPOINT"
log "  Credential:  $CRED_ENDPOINT"

# ------------------------------------------------------------
# 10. Corregir CRLF en entrypoint.sh (Windows)
# ------------------------------------------------------------
sed -i 's/\r//' greengrass-core/entrypoint.sh
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
