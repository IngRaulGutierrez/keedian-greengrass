# keedian-greengrass — Contexto del proyecto

## Propósito

Gateway industrial basado en **AWS IoT Greengrass v2** corriendo en Docker.
Recibe los 6 componentes industriales de **keedian-link** vía cloud deployment desde AWS
IoT Greengrass y los ejecuta en el dispositivo de borde.

## Flujo completo

```
keedian-link (repositorio separado)
  └── CI/CD (GitHub Actions)
        ├── Sube artefactos a S3: s3://keedian-edge-gateway-artifacts/
        └── Registra componentes: aws greengrassv2 create-component-version
                  │
                  ▼
        AWS IoT Greengrass (nube)
          └── Deployment → Thing: THING_NAME
                  │
                  ▼
        keedian-greengrass (este proyecto, en el dispositivo)
          ├── docker compose up --build -d
          │     ├── keedian-gw-postgres (PostgreSQL 16)
          │     └── greengrass-core
          │           └── entrypoint.sh
          │                 ├── Auto-provisiona desde AWS (boto3):
          │                 │     ├── Descarga AmazonRootCA1.pem
          │                 │     ├── Crea Thing si no existe
          │                 │     ├── Crea política GreengrassIoTPolicy si no existe
          │                 │     ├── Genera certificado X.509 → persiste en ./config/
          │                 │     └── Obtiene endpoints dinámicamente
          │                 ├── Genera config.yaml (solo Nucleus)
          │                 ├── Crea venv /opt/keedian-gw/venv
          │                 ├── Crea gateway.yaml
          │                 └── Lanza Nucleus
          └── Nucleus recibe deployment de AWS → descarga componentes desde S3
                  │
                  ▼
        6 componentes corriendo (via IPC local keedian/local/...)
          ├── com.keedian.config-manager  — distribuye configuración vía IPC
          ├── com.keedian.db-layer        — gestiona PostgreSQL (outbox, measurements)
          ├── com.keedian.task-manager    — orquesta tareas de polling
          ├── com.keedian.modbus-adapter  — lee dispositivos Modbus TCP/RTU
          ├── com.keedian.bacnet-adapter  — lee dispositivos BACnet
          └── com.keedian.data-uploader   — publica a AWS IoT Core
                  │
                  ▼
        AWS IoT Core — tópico: keedian/{THING_NAME}/telemetry
```

## Decisiones arquitectónicas importantes

- **PostgreSQL** (no MariaDB): migración intencional respecto a keedian-link
- **AWS IoT Core** como destino de telemetría (no ThingsBoard)
- **Entornos separados**: keedian-link y keedian-greengrass corren en dispositivos distintos
- **Sin bind mount de componentes**: los componentes llegan exclusivamente vía cloud deployment
- **Auto-provisionamiento**: certificados y endpoints se obtienen de AWS al primer arranque
- **Venv compartido**: `/opt/keedian-gw/venv` creado en entrypoint.sh para los componentes

## Estructura del proyecto

```
keedian-greengrass/
├── greengrass-core/
│   ├── Dockerfile       # amazoncorretto:11-al2023 + Python 3.11 + boto3 + dependencias
│   └── entrypoint.sh    # Auto-provisiona AWS y lanza el Nucleus
├── config/              # Certificados X.509 — generados automáticamente, NO versionados
├── data/                # Persistencia local: gateway.db (SQLite de db-layer)
├── docker-compose.yml   # postgres + greengrass; sin redes externas
├── .env                 # 5 variables: credenciales AWS + THING_NAME + DEVICE_NAME
└── .env.example         # Plantilla
```

## Variables de entorno (.env)

| Variable | Descripción |
|---|---|
| `AWS_ACCESS_KEY_ID` | Access key IAM con permisos IoT + Greengrass |
| `AWS_SECRET_ACCESS_KEY` | Secret key IAM |
| `AWS_REGION` | Región AWS (us-east-2) |
| `THING_NAME` | Nombre del Thing en AWS IoT Core |
| `DEVICE_NAME` | Nombre descriptivo del dispositivo |

Los endpoints (`IOT_DATA_ENDPOINT`, `IOT_CRED_ENDPOINT`) se obtienen automáticamente.

## Permisos IAM requeridos

El usuario IAM necesita permisos sobre:
- `iot:DescribeThing`, `iot:CreateThing`
- `iot:CreateKeysAndCertificate`, `iot:UpdateCertificate`
- `iot:GetPolicy`, `iot:CreatePolicy`
- `iot:AttachPolicy`, `iot:AttachThingPrincipal`
- `iot:DescribeEndpoint`
- `greengrass:*`

## Comandos habituales

```bash
# Levantar
docker compose up --build -d

# Ver logs del Nucleus y provisionamiento
docker logs greengrass-core

# Ver log de un componente (una vez desplegado desde AWS)
docker exec greengrass-core tail -f /greengrass/v2/logs/com.keedian.config-manager.log

# Bajar (conserva certificados en ./config/ y datos en ./data/)
docker compose down

# Bajar y limpiar volúmenes (los certificados en ./config/ se conservan igualmente)
docker compose down -v
```

## Base de datos PostgreSQL

- **Contenedor**: `keedian-gw-postgres`
- **Host desde greengrass-core**: `keedian-gw-postgres`
- **Puerto**: `5432`
- **DB / Usuario / Contraseña**: `keedian_gw` / `keedian_gw` / `keedian_dev_pass`
- **Tablas clave**: `outbox` (store-and-forward), `measurements` (histórico confirmado)
- **Estado de outbox**: `PENDING` → `SENDING` → `SENT` / `FAILED` (enum en mayúsculas en PostgreSQL)

## Contexto de gateway.db

`./data/gateway.db` es un SQLite local gestionado por `db-layer` en `/var/lib/keedian-gw/data/gateway.db`.
Tablas: `outbox`, `measurements`, `config_versions`, `component_logs`, `health_metrics`.

## Lo que este proyecto NO hace

- No contiene lógica de protocolos industriales (Modbus, BACnet) — eso es keedian-link
- No registra componentes en AWS — eso lo hace el CI/CD de keedian-link
- No crea deployments en AWS — eso se hace manualmente o vía consola AWS
- No tiene scripts de setup/provisioning manuales — todo es automático en entrypoint.sh
