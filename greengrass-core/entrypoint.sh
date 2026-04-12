#!/bin/bash
set -e

echo "[Greengrass] Iniciando configuración..."

VERSION="1.0.2"
ARTIFACT_PATH="/greengrass/v2/packages/artifacts-unarchived/com.example.HelloWorld/${VERSION}"
HW_ENABLED="${ENABLE_HELLO_WORLD:-false}"

# Crear directorios base
mkdir -p /greengrass/v2/config

# Copiar certificados
cp /tmp/certs/device.pem.crt    /greengrass/v2/device.pem.crt
cp /tmp/certs/private.pem.key   /greengrass/v2/private.pem.key
cp /tmp/certs/AmazonRootCA1.pem /greengrass/v2/AmazonRootCA1.pem

echo "[Greengrass] Certificados copiados."

# Copiar artefactos HelloWorld solo si está habilitado
if [ "$HW_ENABLED" = "true" ] || [ "$HW_ENABLED" = "TRUE" ]; then
    mkdir -p "${ARTIFACT_PATH}"
    cp -r /tmp/components/com.example.HelloWorld/artifacts/* "${ARTIFACT_PATH}/"
    echo "[Greengrass] Artefactos HelloWorld copiados."
else
    echo "[Greengrass] HelloWorld deshabilitado (ENABLE_HELLO_WORLD=${HW_ENABLED})."
fi

# Generar config.yaml — sección base (sistema + Nucleus)
# Nota: La operacion correcta para el AuthorizationModule es aws.greengrass#PublishToIoTCore
# (nombre Smithy interno), no aws.greengrass.ipc.mqttproxy#PublishToIoTCore
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

# Agregar servicio HelloWorld condicionalmente
if [ "$HW_ENABLED" = "true" ] || [ "$HW_ENABLED" = "TRUE" ]; then
    cat >> /greengrass/v2/config/config.yaml <<EOF
  com.example.HelloWorld:
    componentType: "GENERIC"
    version: "${VERSION}"
    lifecycle:
      run:
        script: "python3 -u ${ARTIFACT_PATH}/hello_world.py"
        requiresPrivilege: false
    configuration:
      accessControl:
        aws.greengrass.ipc.mqttproxy:
          "com.example.HelloWorld:mqtt:1":
            policyDescription: "Permite publicar en hello/world via IoT Core"
            operations:
              - "aws.greengrass#PublishToIoTCore"
            resources:
              - "hello/world"
  main:
    dependencies:
      - com.example.HelloWorld
EOF
else
    cat >> /greengrass/v2/config/config.yaml <<EOF
  main:
    dependencies: []
EOF
fi

echo "[Greengrass] config.yaml base generado."

# Agregar componentes keedian-link leyendo sus recetas
echo "[Greengrass] Configurando componentes keedian-link desde recetas..."
python3 - << 'PYEOF'
import sys, json, os, re

COMP_DIR   = '/keedian-components'
CFG        = '/greengrass/v2/config/config.yaml'
THING_NAME = os.environ.get('THING_NAME', '')

COMPONENTS = [
    ('com.keedian.config-manager',  '1.1.9',  'config-manager'),
    ('com.keedian.db-layer',        '1.2.2',  'db-layer'),
    ('com.keedian.task-manager',    '1.1.8',  'task-manager'),
    ('com.keedian.modbus-adapter',  '1.3.2',  'modbus-adapter'),
    ('com.keedian.bacnet-adapter',  '1.1.6',  'bacnet-adapter'),
    ('com.keedian.data-uploader',   '1.2.2',  'data-uploader'),
]

def build_access_control_yaml(access_control):
    """Render accessControl dict as YAML block (indented 4 spaces from component name)."""
    if not access_control:
        return ''
    lines = ['    configuration:', '      accessControl:']
    for namespace, policies in access_control.items():
        lines.append(f'        {namespace}:')
        for policy_id, policy in policies.items():
            lines.append(f'          "{policy_id}":')
            desc = policy.get('policyDescription', '').replace('"', '\\"')
            lines.append(f'            policyDescription: "{desc}"')
            lines.append(f'            operations:')
            for op in policy.get('operations', []):
                lines.append(f'              - "{op}"')
            lines.append(f'            resources:')
            for res in policy.get('resources', []):
                lines.append(f'              - "{res}"')
    return '\n'.join(lines) + '\n'

with open(CFG) as f:
    config = f.read()

added = []
for name, ver, dirname in COMPONENTS:
    artifacts    = f'{COMP_DIR}/{dirname}/artifacts'
    recipe_file  = f'{COMP_DIR}/{dirname}/recipes/{name}-{ver}.json'

    if not os.path.exists(recipe_file):
        print(f'[entrypoint] WARN: receta no encontrada: {recipe_file}', file=sys.stderr)
        continue

    try:
        with open(recipe_file) as f:
            recipe = json.load(f)
    except Exception as e:
        print(f'[entrypoint] WARN: error leyendo {recipe_file}: {e}', file=sys.stderr)
        continue

    # Extraer el script del lifecycle (Manifests[*].Lifecycle.Run)
    script = None
    for manifest in recipe.get('Manifests', []):
        lifecycle = manifest.get('Lifecycle', {})
        run = lifecycle.get('Run', lifecycle.get('run'))
        if isinstance(run, dict):
            script = run.get('Script') or run.get('script')
        elif isinstance(run, str):
            script = run
        if script:
            break

    if not script:
        print(f'[entrypoint] WARN: lifecycle script no encontrado en {recipe_file}', file=sys.stderr)
        continue

    script = script.replace('{artifacts:path}', artifacts)
    script = script.replace('{artifacts:decompressedPath}', artifacts)

    # Sustituir {iot:thingName} con el valor real del Thing
    script = script.replace('{iot:thingName}', THING_NAME)

    # Sustituir {configuration:/KEY} con los valores de DefaultConfiguration del recipe.
    # En init-config Greengrass no hace esta sustitución automáticamente.
    default_cfg = recipe.get('ComponentConfiguration', {}).get('DefaultConfiguration', {})
    def replace_cfg_var(match):
        key = match.group(1)
        val = default_cfg.get(key)
        if val is None:
            # Fallback: INFO para claves de log level, vacío para el resto
            val = 'INFO' if 'level' in key.lower() else ''
        return str(val)
    script = re.sub(r'\{configuration:/(\w+)\}', replace_cfg_var, script)

    # Escapar para YAML double-quoted string:
    #   \  → \\  (barra literal)
    #   "  → \"  (comilla literal)
    #   \n → \n  (newline como escape YAML, no plegado a espacio por SnakeYAML)
    script_esc = script.replace('\\', '\\\\').replace('"', '\\"').replace('\n', '\\n')

    # Extraer accessControl de DefaultConfiguration del recipe
    access_control = default_cfg.get('accessControl', {})
    ac_yaml = build_access_control_yaml(access_control)

    config += (
        f'  {name}:\n'
        f'    componentType: "GENERIC"\n'
        f'    version: "{ver}"\n'
        f'    lifecycle:\n'
        f'      run:\n'
        f'        script: "{script_esc}"\n'
        f'        requiresPrivilege: false\n'
    )
    if ac_yaml:
        config += ac_yaml
    added.append(name)
    print(f'[entrypoint] Configurado: {name}={ver}')

if added:
    extra = '\n      - '.join(added)
    if '      - com.example.HelloWorld' in config:
        # HelloWorld habilitado: agregar keedian después de él
        config = config.replace(
            '      - com.example.HelloWorld',
            f'      - com.example.HelloWorld\n      - {extra}'
        )
    else:
        # HelloWorld deshabilitado: reemplazar dependencies: [] con lista keedian
        config = config.replace(
            '    dependencies: []\n',
            f'    dependencies:\n      - {extra}\n'
        )

with open(CFG, 'w') as f:
    f.write(config)

print(f'[entrypoint] config.yaml listo — {len(added)} componentes keedian-link configurados.')
PYEOF

# Crear directorios requeridos por los componentes
mkdir -p /var/lib/keedian-gw/configs /var/lib/keedian-gw/profiles /var/lib/keedian-gw/data
echo "[Greengrass] Directorios /var/lib/keedian-gw/ listos."

# Crear venv compartido si no existe e instalar dependencias Python
VENV_PATH="/opt/keedian-gw/venv"
VENV_STAMP="${VENV_PATH}/.installed"
if [ ! -f "$VENV_STAMP" ]; then
    echo "[Greengrass] Creando venv en ${VENV_PATH}..."
    python3 -m venv "${VENV_PATH}"
    "${VENV_PATH}/bin/pip" install --quiet --no-cache-dir \
        structlog tenacity httpx \
        "sqlalchemy[asyncio]" aiosqlite aiomysql \
        pydantic pyyaml awsiotsdk
    touch "${VENV_STAMP}"
    echo "[Greengrass] Venv listo con dependencias instaladas."
else
    echo "[Greengrass] Venv ya existe (${VENV_PATH})."
fi

# Crear gateway.yaml si no existe (el config-manager lo necesita al arrancar)
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

buffering:
  local_db: mysql
  db_host: tuten-gw-mariadb
  db_port: 3306
  db_name: tuten_gw
  db_user: tuten_gw
  db_password: tuten_dev_pass

cloud:
  tuten_mqtt:
    enabled: true
    broker: "tuten-gw-mqtt"
    port: 1883
    client_id: "${GW_ID}"
    qos: 1
    keepalive: 60
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
