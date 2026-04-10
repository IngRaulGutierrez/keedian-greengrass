# AWS IoT Greengrass — Hello World en Docker Desktop (Windows)

Guía completa para levantar un proyecto AWS IoT Greengrass v2 localmente en Docker Desktop
sobre Windows, publicando mensajes Hello World a AWS IoT Core.

---

## Arquitectura

```
Windows (Docker Desktop — Linux Containers)
└── Contenedor: greengrass-core
    ├── Java — Greengrass Nucleus v2.16.1
    │     └── CONNECTED → AWS IoT Core (us-east-2)
    └── Python — com.example.HelloWorld v1.0.2
          └── Publica cada 5s → topic: hello/world
                  └── AWS IoT MQTT Test Client → ✓
```

```
keedian-greengrass/
├── SETUP.md
├── docker-compose.yml
├── iot-policy.json
├── config/
│   ├── AmazonRootCA1.pem
│   ├── device.pem.crt
│   ├── private.pem.key
│   └── public.pem.key
├── greengrass-core/
│   ├── Dockerfile
│   └── entrypoint.sh
└── components/
    └── com.example.HelloWorld/
        ├── recipe.yaml
        └── artifacts/
            └── hello_world.py
```

---

## Paso 1 — Pre-requisitos en Windows

### 1.1 Docker Desktop

- Descargar e instalar Docker Desktop desde el sitio oficial.
- Abrir Docker Desktop y verificar que esté en modo **Linux containers**:
  click derecho en el ícono de la barra de tareas → _"Switch to Linux containers"_.
- Verificar instalación:

```bash
docker --version
# Docker version 28.0.4
```

> **Si Docker no es reconocido en PowerShell** (`The term 'docker' is not recognized...`):
>
> 1. Verificar que el ejecutable existe:
>    ```powershell
>    ls "C:\Program Files\Docker\Docker\resources\bin\docker.exe"
>    ```
> 2. Agregar al PATH del sistema (**PowerShell como Administrador**):
>    ```powershell
>    [System.Environment]::SetEnvironmentVariable(
>      'Path',
>      [System.Environment]::GetEnvironmentVariable('Path', 'Machine') + ';C:\Program Files\Docker\Docker\resources\bin',
>      'Machine'
>    )
>    ```
> 3. Cerrar y reabrir la terminal.
> 4. Asegurarse de que Docker Desktop esté abierto y el servicio esté activo (ícono de ballena en la barra de tareas).

### 1.2 AWS CLI

- Descargar e instalar AWS CLI v2:
  `https://awscli.amazonaws.com/AWSCLIV2.msi`

- Agregar al PATH del sistema (PowerShell como Administrador):

```powershell
[System.Environment]::SetEnvironmentVariable(
  "Path",
  $env:Path + ";C:\Program Files\Amazon\AWSCLIV2",
  [System.EnvironmentVariableTarget]::Machine
)
```

- Cerrar y reabrir la terminal, luego verificar:

```bash
aws --version
# aws-cli/2.34.24 Python/3.14.3 Windows/11 exe/AMD64
```

### 1.3 Configurar credenciales AWS

```bash
aws configure
# AWS Access Key ID:     [access key del usuario IAM]
# AWS Secret Access Key: [secret key del usuario IAM]
# Default region name:   us-east-2
# Default output format: json
```

Verificar identidad activa:

```bash
aws sts get-caller-identity
```

### 1.4 Permisos IAM requeridos

> **Acción en AWS Console (usuario administrador):**
> Ir a **IAM → Users → [tu usuario] → Permissions → Add permissions → Attach policies directly**
> y adjuntar las siguientes políticas administradas:

| Política | Propósito |
|----------|-----------|
| `AWSIoTFullAccess` | Crear Things, certificados y políticas IoT |
| `AWSGreengrassFullAccess` | Crear componentes y deployments |
| `AmazonS3FullAccess` | Subir artefactos de componentes |

---

## Paso 2 — Crear recursos en AWS IoT Core

Todos los comandos se ejecutan en la región `us-east-2` (Ohio).

### 2.1 Crear el Thing

```bash
aws iot create-thing \
  --thing-name GreengrassDockerCore \
  --region us-east-2
```

### 2.2 Crear certificados X.509

```bash
aws iot create-keys-and-certificate \
  --set-as-active \
  --certificate-pem-outfile "config/device.pem.crt" \
  --public-key-outfile "config/public.pem.key" \
  --private-key-outfile "config/private.pem.key" \
  --region us-east-2
```

> Guardar el `certificateArn` del output. Se usa en los siguientes pasos.

### 2.3 Crear política IoT

El archivo `iot-policy.json` contiene:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "iot:Connect",
        "iot:Publish",
        "iot:Subscribe",
        "iot:Receive",
        "iot:AssumeRoleWithCertificate",
        "greengrass:*"
      ],
      "Resource": "*"
    }
  ]
}
```

```bash
aws iot create-policy \
  --policy-name GreengrassDockerPolicy \
  --policy-document file://iot-policy.json \
  --region us-east-2
```

### 2.4 Adjuntar política y certificado al Thing

```bash
CERT_ARN="arn:aws:iot:us-east-2:ACCOUNT_ID:cert/XXXXX"

aws iot attach-policy \
  --policy-name GreengrassDockerPolicy \
  --target $CERT_ARN \
  --region us-east-2

aws iot attach-thing-principal \
  --thing-name GreengrassDockerCore \
  --principal $CERT_ARN \
  --region us-east-2
```

### 2.5 Descargar CA raíz de Amazon

```bash
curl -o config/AmazonRootCA1.pem \
  https://www.amazontrust.com/repository/AmazonRootCA1.pem
```

---

## Paso 3 — Crear el Token Exchange Role (en AWS Console)

Greengrass necesita un rol IAM para obtener credenciales temporales desde IoT Core.

> **Acción en AWS Console (usuario administrador):**

### 3.1 Crear el rol IAM

1. Ir a **IAM → Roles → Create role**
2. Seleccionar **Custom trust policy** y pegar:

```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {"Service": "credentials.iot.amazonaws.com"},
    "Action": "sts:AssumeRole"
  }]
}
```

3. **Role name:** `GreengrassV2TokenExchangeRole`
4. Click **Create role**
5. Abrir el rol creado → **Add permissions → Attach policies** → adjuntar `AmazonS3ReadOnlyAccess`

### 3.2 Crear el Role Alias en IoT Core

> **Importante:** crear en la misma región que el resto del proyecto (**us-east-2**).

1. Ir a **AWS IoT Console → Security → Role Aliases → Create role alias**
2. Completar:
   - **Role alias name:** `GreengrassV2TokenExchangeRoleAlias`
   - **Role:** seleccionar `GreengrassV2TokenExchangeRole`
3. Click **Create**

---

## Paso 4 — Archivos del proyecto

### 4.1 docker-compose.yml

```yaml
version: "3.8"

services:
  greengrass:
    build: ./greengrass-core
    container_name: greengrass-core
    init: true
    volumes:
      - ./config:/tmp/certs:ro
      - ./components:/tmp/components:ro
      - greengrass-root:/greengrass/v2
    environment:
      - AWS_REGION=us-east-2
      - THING_NAME=GreengrassDockerCore
      - IOT_DATA_ENDPOINT=akycruzqpng03-ats.iot.us-east-2.amazonaws.com
      - IOT_CRED_ENDPOINT=c1s8i1z1a3vi3r.credentials.iot.us-east-2.amazonaws.com
    ports:
      - "8883:8883"
    restart: unless-stopped

volumes:
  greengrass-root:
```

> Los endpoints se obtienen con:
> ```bash
> aws iot describe-endpoint --endpoint-type iot:Data-ATS --region us-east-2
> aws iot describe-endpoint --endpoint-type iot:CredentialProvider --region us-east-2
> ```

### 4.2 greengrass-core/Dockerfile

```dockerfile
FROM amazoncorretto:11-al2023

RUN dnf install -y \
    python3 \
    python3-pip \
    unzip \
    sudo \
    shadow-utils \
    && dnf clean all

RUN pip3 install awsiotsdk

RUN curl -s https://d2s8p88vqu9w66.cloudfront.net/releases/greengrass-nucleus-latest.zip \
    -o /tmp/greengrass-nucleus-latest.zip \
    && unzip /tmp/greengrass-nucleus-latest.zip -d /tmp/GreengrassInstaller \
    && rm /tmp/greengrass-nucleus-latest.zip

RUN groupadd --system ggc_group && \
    useradd --system --gid ggc_group ggc_user

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
```

> **Notas:**
> - La imagen base `amazoncorretto:11-al2023` incluye Java 11 en Amazon Linux 2023.
> - `curl` ya viene incluido en la imagen como `curl-minimal` — no reinstalar, causa conflicto.
> - `shadow-utils` es necesario para `groupadd` y `useradd`.
> - El Nucleus se descarga desde el CDN de AWS directamente en la imagen.

### 4.3 greengrass-core/entrypoint.sh

```bash
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
# IMPORTANTE: La operación correcta para el AuthorizationModule interno de Greengrass
# es "aws.greengrass#PublishToIoTCore" (nombre Smithy), NO
# "aws.greengrass.ipc.mqttproxy#PublishToIoTCore" (que es el nombre del recipe para
# cloud deployments). En config.yaml el AuthorizationHandler hace match exacto.
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
```

### 4.4 components/com.example.HelloWorld/recipe.yaml

```yaml
RecipeFormatVersion: "2020-01-25"
ComponentName: com.example.HelloWorld
ComponentVersion: "1.0.2"
ComponentDescription: "Publica un mensaje Hello World en IoT Core cada 5 segundos"
ComponentPublisher: "Keedian"
ComponentDependencies:
  aws.greengrass.Nucleus:
    VersionRequirement: ">=2.0.0"
ComponentConfiguration:
  DefaultConfiguration:
    accessControl:
      aws.greengrass.ipc.mqttproxy:
        "com.example.HelloWorld:mqtt:1":
          policyDescription: "Permite publicar en hello/world via IoT Core"
          operations:
            - aws.greengrass.ipc.mqttproxy#PublishToIoTCore
          resources:
            - "hello/world"
Manifests:
  - Platform:
      os: linux
    Lifecycle:
      Run:
        Script: python3 {artifacts:path}/hello_world.py
    Artifacts:
      - URI: "s3://keedian-greengrass-artifacts-320901122104/artifacts/com.example.HelloWorld/1.0.1/hello_world.py"
        Unarchive: NONE
```

> **Notas importantes sobre el recipe:**
> - No incluir el paso `Install` para `pip3 install awsiotsdk` si el SDK ya está
>   instalado en la imagen Docker — causa error de permisos al correr como `ggc_user`.
> - El `accessControl` en el recipe usa `aws.greengrass.ipc.mqttproxy#PublishToIoTCore`
>   para cloud deployments. Pero en el **config.yaml local** (sin cloud deployment),
>   se debe usar `aws.greengrass#PublishToIoTCore` — ver Paso 4.3 y sección de
>   troubleshooting para más detalles.
> - Los errores de validación que muestra VS Code en el recipe son falsos positivos
>   del validador YAML — el formato es correcto para Greengrass.
> - El recipe en `packages/recipes/` copiado manualmente NO aplica su `accessControl`
>   ni su `lifecycle` al config tree de Greengrass. Esos solo se aplican via deployment.

### 4.5 components/com.example.HelloWorld/artifacts/hello_world.py

```python
import awsiot.greengrasscoreipc
from awsiot.greengrasscoreipc.model import (
    PublishToIoTCoreRequest,
    QOS
)
import time
import json

TOPIC = "hello/world"
TIMEOUT = 10

print("[HelloWorld] Conectando al IPC de Greengrass...")
ipc_client = awsiot.greengrasscoreipc.connect()
print("[HelloWorld] Conectado. Iniciando publicación de mensajes...")

count = 1
while True:
    message = {
        "message": "Hello World from Greengrass on Docker!",
        "count": count,
        "timestamp": time.time()
    }

    request = PublishToIoTCoreRequest(
        topic_name=TOPIC,
        payload=bytes(json.dumps(message), "utf-8"),
        qos=QOS.AT_LEAST_ONCE
    )

    operation = ipc_client.new_publish_to_iot_core()
    operation.activate(request)
    operation.get_response().result(TIMEOUT)

    print(f"[HelloWorld] #{count} Publicado en '{TOPIC}': {message['message']}")
    count += 1
    time.sleep(5)
```

> **Nota:** El script bufferiza stdout cuando corre como subprocess. Los logs
> aparecen en lote una vez que el buffer se llena — comportamiento normal en
> Amazon Linux 2023 sin TTY.

---

## Paso 5 — Levantar el contenedor y desplegar el componente

### 5.1 Construir y levantar el contenedor

```bash
docker compose up --build -d
```

Verificar que el Nucleus se conectó a AWS IoT Core:

```bash
docker logs greengrass-core
# Debe mostrar: "Launched Nucleus successfully."
```

### 5.2 Crear bucket S3 y subir el artefacto

```bash
aws s3 mb s3://keedian-greengrass-artifacts-320901122104 --region us-east-2

aws s3 cp components/com.example.HelloWorld/artifacts/hello_world.py \
  s3://keedian-greengrass-artifacts-320901122104/artifacts/com.example.HelloWorld/1.0.1/hello_world.py \
  --region us-east-2
```

### 5.3 Registrar el componente en Greengrass

```bash
aws greengrassv2 create-component-version \
  --inline-recipe fileb://components/com.example.HelloWorld/recipe.yaml \
  --region us-east-2
```

### 5.4 Crear el deployment

> **Nota crítica:** En Greengrass Nucleus 2.16.1, el `accessControl` del recipe
> requiere que en el deployment se pase `"operations": ["*"]` para que la
> autorización IPC funcione correctamente. La operación específica
> `aws.greengrass.ipc.mqttproxy#PublishToIoTCore` genera el error
> `Operation not registered` en esta versión.

```bash
aws greengrassv2 create-deployment \
  --target-arn "arn:aws:iot:us-east-2:ACCOUNT_ID:thing/GreengrassDockerCore" \
  --deployment-name "HelloWorldDeployment" \
  --components '{
    "com.example.HelloWorld": {
      "componentVersion": "1.0.2",
      "configurationUpdate": {
        "merge": "{\"accessControl\":{\"aws.greengrass.ipc.mqttproxy\":{\"com.example.HelloWorld:mqtt:1\":{\"policyDescription\":\"Allow all MQTT proxy operations\",\"operations\":[\"*\"],\"resources\":[\"*\"]}}}}"
      }
    }
  }' \
  --region us-east-2
```

Verificar estado del deployment:

```bash
aws greengrassv2 get-deployment \
  --deployment-id "DEPLOYMENT_ID" \
  --region us-east-2 \
  --query 'deploymentStatus' \
  --output text
# COMPLETED
```

Verificar logs del componente dentro del contenedor:

```bash
# En Windows con Git Bash usar MSYS_NO_PATHCONV=1
MSYS_NO_PATHCONV=1 docker exec greengrass-core \
  tail -20 /greengrass/v2/logs/com.example.HelloWorld.log
```

---

## Paso 6 — Verificar mensajes en AWS IoT Console

> **Acción en AWS Console:**

1. Ir a **AWS IoT Console** — verificar que la región sea **US East (Ohio) — us-east-2**
2. Navegar a **Probar → Cliente de prueba de MQTT**
3. Click en la pestaña **"Suscribirse a un tema"**
4. En **Filtro de tema** escribir: `hello/world`
5. Click en **Suscribirse**

Resultado esperado (cada 5 segundos):

```json
{
  "message": "Hello World from Greengrass on Docker!",
  "count": 222,
  "timestamp": 1775269385.817
}
```

---

## Comandos de operación

### Ver logs en tiempo real

```bash
# Log del Nucleus
MSYS_NO_PATHCONV=1 docker exec greengrass-core \
  tail -f /greengrass/v2/logs/greengrass.log

# Log del componente Hello World
MSYS_NO_PATHCONV=1 docker exec greengrass-core \
  tail -f /greengrass/v2/logs/com.example.HelloWorld.log
```

### Verificar procesos dentro del contenedor

```bash
MSYS_NO_PATHCONV=1 docker exec greengrass-core \
  cat /proc/385/cmdline | tr '\0' ' '
# sudo -n -E -H -u ggc_user -g ggc_group -- sh -c python3 .../hello_world.py
```

### Detener y limpiar

```bash
# Detener el contenedor
docker compose down

# Eliminar volúmenes (borra la config del Nucleus)
docker compose down -v
```

### Reconstruir desde cero

```bash
docker compose down -v
docker compose up --build -d
```

---

## Notas de troubleshooting

| Problema | Causa | Solución |
|----------|-------|----------|
| `docker` no reconocido en PowerShell | Docker Desktop no está en el PATH del sistema | Agregar `C:\Program Files\Docker\Docker\resources\bin` al PATH como Administrador (ver Paso 1.1) |
| Docker Desktop instalado pero sigue sin reconocerse | PATH modificado pero terminal no reiniciada | Cerrar y reabrir completamente PowerShell o VS Code |
| `exec /entrypoint.sh failed: No such file or directory` | `entrypoint.sh` fue creado/editado en Windows con saltos de línea CRLF | Convertir a LF: `sed -i 's/\r//' greengrass-core/entrypoint.sh` y reconstruir |
| `dependencies is already a container, cannot become a leaf` | Volumen Docker con estado corrupto de ejecuciones anteriores | Limpiar completamente: `docker compose down -v && docker compose up -d` |
| `Not Authorized` al publicar en IPC | Nombre de operación incorrecto en `accessControl` del config.yaml | En config.yaml usar `aws.greengrass#PublishToIoTCore` (nombre Smithy interno), NO `aws.greengrass.ipc.mqttproxy#PublishToIoTCore` |
| `accessControl` en recipe manual no aplica | Greengrass solo aplica `accessControl` de recipes durante un deployment, no al copiarlos manualmente a `packages/recipes/` | Definir el `accessControl` directamente en el `config.yaml` (ver Paso 4.3) |
| Componente va a FINISHED sin ejecutarse | `lifecycle` no definido en config.yaml; Greengrass no lee el lifecycle de un recipe copiado manualmente | Definir el `lifecycle.run.script` directamente en el `config.yaml` |
| Log del componente sin output (script corre silencioso) | Python bufferiza stdout cuando corre como subprocess sin TTY | Agregar flag `-u`: `python3 -u hello_world.py` |
| `curl` conflicts en Dockerfile | `amazoncorretto:11-al2023` ya trae `curl-minimal` | No instalar `curl`, ya está disponible |
| `groupadd: command not found` | Falta `shadow-utils` en Amazon Linux 2023 | Agregar `shadow-utils` al `dnf install` |
| `pip3 install` falla como `ggc_user` | Sin permisos en `/home/ggc_user` | No incluir el paso `Install` en el recipe si el SDK está en la imagen |
| `Operation not registered` en IPC (cloud deployment) | El nombre de operación específico no está registrado en Nucleus 2.16.1 | Usar `"operations": ["*"]` en el `configurationUpdate` del deployment |
| Deployment `FAILED` con rollback | El componente crashea durante el deployment y Greengrass hace rollback | Corregir el error antes de redeployar — crear nueva versión del componente |
| Rutas Unix en Git Bash | Git Bash convierte `/path` a `C:/Program Files/Git/path` | Usar `MSYS_NO_PATHCONV=1` antes de comandos `docker exec` con rutas absolutas |
| Región incorrecta | Resources creados en región diferente | Todos los recursos AWS deben estar en la misma región (`us-east-2` en este proyecto) |

---

## Diferencias entre config.yaml local y cloud deployment

Al ejecutar Greengrass en Docker sin cloud deployment activo, la forma de definir
componentes es diferente a la documentación oficial de AWS (que asume cloud deployment):

| Aspecto | Cloud Deployment | Config.yaml local (este proyecto) |
|---------|-----------------|-------------------------------------|
| Lifecycle | Definido en recipe, aplicado por Greengrass durante deployment | Debe definirse en `config.yaml` bajo `services.{component}.lifecycle` |
| accessControl | Leído del recipe por el AuthorizationModule | Debe definirse en `config.yaml` bajo `services.{component}.configuration.accessControl` |
| Nombre de operación IPC | `aws.greengrass.ipc.mqttproxy#PublishToIoTCore` | `aws.greengrass#PublishToIoTCore` (nombre Smithy interno) |
| Recipe en `packages/recipes/` | Greengrass lo coloca ahí después del deployment | Copiar manualmente NO aplica lifecycle ni accessControl |

> **Razón técnica:** El `AuthorizationHandler` de Greengrass usa comparación de string
> exacta. Cuando el request llega desde el MQTT Proxy, la operación se identifica
> internamente como `aws.greengrass#PublishToIoTCore` (namespace Smithy). En un recipe
> para cloud deployment, Greengrass normaliza `aws.greengrass.ipc.mqttproxy#PublishToIoTCore`
> durante el proceso de deployment. En config.yaml ese proceso de normalización no ocurre,
> por lo que se debe usar el nombre interno directamente.

---

## Recursos AWS creados

| Recurso | Nombre | Región |
|---------|--------|--------|
| IoT Thing | `GreengrassDockerCore` | us-east-2 |
| Certificado X.509 | `644f598f...` | us-east-2 |
| Política IoT | `GreengrassDockerPolicy` | us-east-2 |
| IAM Role | `GreengrassV2TokenExchangeRole` | Global |
| Role Alias IoT | `GreengrassV2TokenExchangeRoleAlias` | us-east-2 |
| Bucket S3 | `keedian-greengrass-artifacts-320901122104` | us-east-2 |
| Componente Greengrass | `com.example.HelloWorld` v1.0.2 | us-east-2 |
