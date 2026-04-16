# keedian-greengrass

AWS IoT Greengrass v2 corriendo en Docker. Actúa como gateway industrial que recibe los componentes de **keedian-link** vía cloud deployment desde AWS IoT Greengrass.

---

## Arquitectura

```
AWS IoT Greengrass (nube)
  └── Deployment ──────────────────────────────────────────────┐
        └── com.keedian.config-manager                         │
        └── com.keedian.db-layer                               │
        └── com.keedian.task-manager                           ▼
        └── com.keedian.modbus-adapter          keedian-greengrass (dispositivo)
        └── com.keedian.bacnet-adapter          ├── greengrass-core   (Nucleus)
        └── com.keedian.data-uploader           └── keedian-gw-postgres (PostgreSQL)
                  │
                  ▼
          AWS IoT Core
          keedian/{THING_NAME}/telemetry
```

El Nucleus arranca, auto-provisiona certificados y endpoints desde AWS, y espera el cloud deployment con los 6 componentes industriales.

---

## Requisitos

- Docker instalado en el dispositivo
- Acceso a internet (provisionamiento y descarga de componentes desde AWS)
- Credenciales IAM con permisos sobre IoT y Greengrass

---

## Configuración

```bash
cp .env.example .env
```

Edita `.env` con solo 4 valores:

| Variable | Descripción |
|---|---|
| `AWS_ACCESS_KEY_ID` | Access key del usuario IAM |
| `AWS_SECRET_ACCESS_KEY` | Secret key del usuario IAM |
| `AWS_REGION` | Región AWS (ej: `us-east-2`) |
| `THING_NAME` | Nombre del Thing en AWS IoT Core |
| `DEVICE_NAME` | Nombre descriptivo del dispositivo |

Los endpoints de IoT Core, certificados y CA raíz se obtienen y crean **automáticamente** en el primer arranque.

---

## Levantar el proyecto

```bash
docker compose up --build -d
```

En el **primer arranque** el contenedor ejecuta automáticamente:

1. Descarga `AmazonRootCA1.pem` desde Amazon Trust Services
2. Crea el Thing en AWS IoT Core si no existe
3. Crea la política IoT si no existe
4. Genera el certificado X.509, lo activa y lo adjunta al Thing
5. Obtiene los endpoints de IoT Core dinámicamente
6. Genera `config.yaml` con las credenciales del dispositivo
7. Lanza el Nucleus

Los certificados se persisten en `./config/` para ser reutilizados en reinicios posteriores.

En arranques **posteriores** reutiliza los certificados existentes y solo obtiene los endpoints de AWS.

Verificar que el Nucleus arrancó:

```bash
docker logs greengrass-core | grep "Nucleus"
# Debe mostrar: "Launched Nucleus successfully."
```

Una vez activo, AWS IoT Greengrass envía el cloud deployment con los 6 componentes de keedian-link.

---

## Bajar el proyecto

```bash
# Solo detener (certificados y datos se conservan)
docker compose down

# Detener y limpiar volúmenes (los certificados en ./config/ se conservan igualmente)
docker compose down -v
```

---

## Ver logs

```bash
# Nucleus y provisionamiento
docker logs greengrass-core

# Componente específico (una vez desplegado)
docker exec greengrass-core tail -f /greengrass/v2/logs/com.keedian.config-manager.log

# Listar logs disponibles
docker exec greengrass-core ls /greengrass/v2/logs/
```

---

## Estructura del proyecto

```
keedian-greengrass/
├── greengrass-core/
│   ├── Dockerfile          # Imagen del contenedor (Java + Python + Nucleus)
│   └── entrypoint.sh       # Auto-provisiona AWS y lanza el Nucleus
├── config/                 # Certificados X.509 (generados automáticamente, no versionados)
├── data/                   # Persistencia local del gateway (no versionada)
├── docker-compose.yml      # Servicios: greengrass-core + keedian-gw-postgres
├── .env                    # Variables de entorno (no versionado)
└── .env.example            # Plantilla de configuración
```
