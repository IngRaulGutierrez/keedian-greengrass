#!/bin/bash
set -e

echo "[Greengrass] Iniciando configuración..."

# Crear directorios base
mkdir -p /greengrass/v2/config
mkdir -p /greengrass/v2/packages/artifacts-unarchived/com.example.HelloWorld/1.0.0

# Copiar certificados
cp /tmp/certs/device.pem.crt    /greengrass/v2/device.pem.crt
cp /tmp/certs/private.pem.key   /greengrass/v2/private.pem.key
cp /tmp/certs/AmazonRootCA1.pem /greengrass/v2/AmazonRootCA1.pem

echo "[Greengrass] Certificados copiados."

# Copiar artefactos del componente Hello World
cp -r /tmp/components/com.example.HelloWorld/artifacts/* \
      /greengrass/v2/packages/artifacts-unarchived/com.example.HelloWorld/1.0.0/

echo "[Greengrass] Componentes copiados."

# Generar config.yaml para el Nucleus
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
echo "[Greengrass] Arrancando Nucleus..."

# Arrancar el Nucleus de Greengrass
exec java -Droot="/greengrass/v2" \
  -Dlog.store=FILE \
  -jar /tmp/GreengrassInstaller/lib/Greengrass.jar \
  --init-config /greengrass/v2/config/config.yaml \
  --component-default-user ggc_user:ggc_group \
  --setup-system-service false
