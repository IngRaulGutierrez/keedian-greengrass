#!/bin/bash
set -e

echo "[Greengrass] Iniciando configuración..."

VERSION="1.0.2"
ARTIFACT_PATH="/greengrass/v2/packages/artifacts-unarchived/com.example.HelloWorld/${VERSION}"

# Crear directorios base
mkdir -p /greengrass/v2/config
mkdir -p ${ARTIFACT_PATH}

# Copiar certificados
cp /tmp/certs/device.pem.crt    /greengrass/v2/device.pem.crt
cp /tmp/certs/private.pem.key   /greengrass/v2/private.pem.key
cp /tmp/certs/AmazonRootCA1.pem /greengrass/v2/AmazonRootCA1.pem

echo "[Greengrass] Certificados copiados."

# Copiar artefactos del componente Hello World
cp -r /tmp/components/com.example.HelloWorld/artifacts/* ${ARTIFACT_PATH}/

echo "[Greengrass] Artefactos copiados."

# Generar config.yaml para el Nucleus
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

echo "[Greengrass] config.yaml generado."
echo "[Greengrass] Arrancando Nucleus..."

# Arrancar el Nucleus de Greengrass
exec java -Droot="/greengrass/v2" \
  -Dlog.store=FILE \
  -jar /tmp/GreengrassInstaller/lib/Greengrass.jar \
  --init-config /greengrass/v2/config/config.yaml \
  --component-default-user ggc_user:ggc_group \
  --setup-system-service false
