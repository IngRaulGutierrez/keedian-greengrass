#!/bin/bash
set -e

echo "[Greengrass] Iniciando configuración..."

# Crear directorios base
mkdir -p /greengrass/v2/config /certs

# ============================================================
# Auto-provisionamiento desde AWS
# Obtiene endpoints, crea certificados si no existen y
# descarga la CA raíz. Usa AWS_ACCESS_KEY_ID y
# AWS_SECRET_ACCESS_KEY del entorno.
# Los certificados se persisten en ./config (bind mount /certs)
# para ser reutilizados en reinicios posteriores.
# ============================================================
python3 - << 'PYEOF'
import boto3, json, os, sys, urllib.request

THING_NAME  = os.environ['THING_NAME']
AWS_REGION  = os.environ['AWS_REGION']
CERT_DIR    = '/certs'
POLICY_NAME = 'GreengrassIoTPolicy'

iot = boto3.client(
    'iot',
    region_name=AWS_REGION,
    aws_access_key_id=os.environ['AWS_ACCESS_KEY_ID'],
    aws_secret_access_key=os.environ['AWS_SECRET_ACCESS_KEY'],
)

cert_file = f'{CERT_DIR}/device.pem.crt'
key_file  = f'{CERT_DIR}/private.pem.key'
ca_file   = f'{CERT_DIR}/AmazonRootCA1.pem'

# --- CA raíz ------------------------------------------------
if not os.path.exists(ca_file):
    print('[provision] Descargando AmazonRootCA1.pem...')
    urllib.request.urlretrieve(
        'https://www.amazontrust.com/repository/AmazonRootCA1.pem',
        ca_file
    )
    print('[provision] CA raíz descargada.')
else:
    print('[provision] AmazonRootCA1.pem ya existe.')

# --- Certificado del dispositivo ----------------------------
if not os.path.exists(cert_file) or not os.path.exists(key_file):
    print(f'[provision] Provisionando certificado para Thing: {THING_NAME}')

    # Crear Thing si no existe
    try:
        iot.describe_thing(thingName=THING_NAME)
        print(f'[provision] Thing "{THING_NAME}" ya existe.')
    except iot.exceptions.ResourceNotFoundException:
        iot.create_thing(thingName=THING_NAME)
        print(f'[provision] Thing "{THING_NAME}" creado.')

    # Crear política IoT si no existe
    policy_doc = json.dumps({
        "Version": "2012-10-17",
        "Statement": [{
            "Effect": "Allow",
            "Action": [
                "iot:Connect",
                "iot:Publish",
                "iot:Subscribe",
                "iot:Receive",
                "greengrass:*"
            ],
            "Resource": "*"
        }]
    })
    try:
        iot.get_policy(policyName=POLICY_NAME)
        print(f'[provision] Política "{POLICY_NAME}" ya existe.')
    except iot.exceptions.ResourceNotFoundException:
        iot.create_policy(policyName=POLICY_NAME, policyDocument=policy_doc)
        print(f'[provision] Política "{POLICY_NAME}" creada.')

    # Crear certificado activo
    resp    = iot.create_keys_and_certificate(setAsActive=True)
    cert_id  = resp['certificateId']
    cert_arn = resp['certificateArn']

    with open(cert_file, 'w') as f:
        f.write(resp['certificatePem'])
    with open(key_file, 'w') as f:
        f.write(resp['keyPair']['PrivateKey'])
    os.chmod(key_file, 0o600)

    # Adjuntar política y Thing al certificado
    iot.attach_policy(policyName=POLICY_NAME, target=cert_arn)
    iot.attach_thing_principal(thingName=THING_NAME, principal=cert_arn)

    print(f'[provision] Certificado creado y adjuntado (id: {cert_id})')
else:
    print('[provision] Certificados existentes encontrados, reutilizando.')

# --- Endpoints dinámicos ------------------------------------
data_ep = iot.describe_endpoint(endpointType='iot:Data-ATS')['endpointAddress']
cred_ep = iot.describe_endpoint(endpointType='iot:CredentialProvider')['endpointAddress']

with open('/tmp/gg_endpoints.env', 'w') as f:
    f.write(f'IOT_DATA_ENDPOINT={data_ep}\n')
    f.write(f'IOT_CRED_ENDPOINT={cred_ep}\n')

print(f'[provision] Data endpoint:  {data_ep}')
print(f'[provision] Cred endpoint:  {cred_ep}')
print('[provision] Provisionamiento completado.')
PYEOF

# Cargar endpoints obtenidos
# shellcheck source=/dev/null
source /tmp/gg_endpoints.env

# Copiar certificados al directorio de Greengrass
cp /certs/device.pem.crt    /greengrass/v2/device.pem.crt
cp /certs/private.pem.key   /greengrass/v2/private.pem.key
cp /certs/AmazonRootCA1.pem /greengrass/v2/AmazonRootCA1.pem

echo "[Greengrass] Certificados listos."

# Generar config.yaml — solo Nucleus
# Los componentes keedian-link llegan vía cloud deployment desde AWS IoT Greengrass
cat > /greengrass/v2/config/config.yaml <<EOF
---
system:
  certificateFilePath: "/greengrass/v2/device.pem.crt"
  privateKeyPath: "/greengrass/v2/private.pem.key"
  rootCaPath: "/greengrass/v2/AmazonRootCA1.pem"
  rootpath: "/greengrass/v2"
  thingName: "${THING_NAME}"
services:
  aws.greengrass.Nucleus:
    componentType: "NUCLEUS"
    configuration:
      awsRegion: "${AWS_REGION}"
      iotRoleAlias: "GreengrassV2TokenExchangeRoleAlias"
      iotDataEndpoint: "${IOT_DATA_ENDPOINT}"
      iotCredEndpoint: "${IOT_CRED_ENDPOINT}"
EOF

echo "[Greengrass] config.yaml generado."

# Crear directorios requeridos por los componentes
mkdir -p /var/lib/keedian-gw/configs /var/lib/keedian-gw/profiles /var/lib/keedian-gw/data
echo "[Greengrass] Directorios /var/lib/keedian-gw/ listos."

# Crear venv compartido si no existe e instalar dependencias Python
VENV_PATH="/opt/keedian-gw/venv"
VENV_STAMP="${VENV_PATH}/.installed_v2"
if [ ! -f "$VENV_STAMP" ]; then
    echo "[Greengrass] Creando venv en ${VENV_PATH}..."
    python3 -m venv "${VENV_PATH}"
    "${VENV_PATH}/bin/pip" install --quiet --no-cache-dir \
        structlog tenacity httpx \
        "sqlalchemy[asyncio]" asyncpg aiomqtt \
        pydantic pyyaml awsiotsdk
    touch "${VENV_STAMP}"
    echo "[Greengrass] Venv listo con dependencias instaladas."
else
    echo "[Greengrass] Venv ya existe (${VENV_PATH})."
fi

# Crear gateway.yaml si no existe
GW_CONFIG="/var/lib/keedian-gw/configs/gateway.yaml"
if [ ! -f "$GW_CONFIG" ]; then
    GW_ID="${THING_NAME:-GreengrassDockerCore}"
    cat > "$GW_CONFIG" <<YAMLEOF
gateway_id: "${GW_ID}"
log_level: "INFO"

network:
  interfaces:
    - name: "eth0"
      role: "uplink"
      metric: 100
  fallback_to_dhcp: true

database:
  connection_string: "postgresql+asyncpg://keedian_gw:keedian_dev_pass@keedian-gw-postgres:5432/keedian_gw"

cloud:
  telemetry:
    level: "standard"
    interval: 300
YAMLEOF
    echo "[Greengrass] gateway.yaml creado en $GW_CONFIG"
else
    echo "[Greengrass] gateway.yaml ya existe, omitiendo creación."
fi

echo "[Greengrass] Arrancando Nucleus..."

exec java -Droot="/greengrass/v2" \
  -Dlog.store=FILE \
  -jar /tmp/GreengrassInstaller/lib/Greengrass.jar \
  --init-config /greengrass/v2/config/config.yaml \
  --component-default-user ggc_user:ggc_group \
  --setup-system-service false
