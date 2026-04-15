# keedian-greengrass

AWS IoT Greengrass v2 corriendo en Docker, integrado con **keedian-link** para desplegar 6 componentes industriales sobre AWS IoT Core.

---

## Arquitectura

```
keedian-link/                        keedian-greengrass/
├── setup.sh  ──────────────────►  ├── setup.sh
│   └── crea keedian-network         │   └── conecta a keedian-network
├── keedian-gw-postgres (5432) ─────  ├── greengrass-core
└── tuten-gw-mqtt    (1883)  ◄─────  │   ├── com.keedian.config-manager
                                     │   ├── com.keedian.db-layer
                                     │   ├── com.keedian.task-manager
                                     │   ├── com.keedian.modbus-adapter
                                     │   ├── com.keedian.bacnet-adapter
                                     │   └── com.keedian.data-uploader
                                     └── components/
                                         └── com.example.HelloWorld
```

Los 6 componentes de **keedian-link** se montan en `/keedian-components/` dentro del contenedor.
Al arrancar, `entrypoint.sh` lee las recetas JSON de cada componente y los registra en `config.yaml`
para que el Nucleus los inicie automáticamente — sin necesidad de `greengrass-cli`.

---

## Requisitos previos

- **[keedian-link](../keedian-link) debe ejecutarse primero** — su `setup.sh` crea la red Docker
  `keedian-network` y Mosquitto (`tuten-gw-mqtt:1883`)
- PostgreSQL (`keedian-gw-postgres:5432`) se levanta automáticamente dentro de este proyecto
- Docker Desktop con Linux containers activo
- AWS CLI, Python 3 (se instalan automáticamente con `install-deps.sh` si faltan)

---

## Primera vez (configuración automática)

### Paso 0 — Instalar dependencias

Si aún no tienes AWS CLI, Docker Desktop o Python 3:

```bash
bash install-deps.sh
```

Compatible con **Windows (Git Bash)**, **macOS** y **Linux**. Instala automáticamente lo que falte.
Si al finalizar indica pasos manuales o reinicio, complétalos antes de continuar.

### Paso 1 — Configurar credenciales

```bash
cp .env.example .env
```

Edita `.env` con tus valores:

| Variable | Descripción |
|----------|-------------|
| `AWS_ACCESS_KEY_ID` | Access key del usuario IAM |
| `AWS_SECRET_ACCESS_KEY` | Secret key del usuario IAM |
| `AWS_REGION` | Región AWS (ej: `us-east-2`) |
| `DEVICE_NAME` | Nombre que aparece en el mensaje MQTT de HelloWorld |
| `THING_NAME` | Nombre del Thing en AWS IoT Core |
| `IOT_DATA_ENDPOINT` | **Se completa automáticamente** |
| `IOT_CRED_ENDPOINT` | **Se completa automáticamente** |
| `KEEDIAN_LINK_COMPONENTS_PATH` | Ruta absoluta a `keedian-link/components/`. Si se deja vacío, `setup.sh` intenta detectarla automáticamente; si no puede, la solicita de forma interactiva |

> **Windows/WSL**: las rutas deben usar formato Linux. Ejemplo:
> `KEEDIAN_LINK_COMPONENTS_PATH=/mnt/d/Keedian/Data Ingestion/keedian-link/components`

### Paso 2 — Ejecutar el setup

> Asegúrate de haber ejecutado primero el `setup.sh` de **keedian-link**.

```bash
bash setup.sh
```

El script ejecuta automáticamente:

1. Verifica e instala dependencias faltantes (AWS CLI, Docker, Python)
2. Valida credenciales AWS
3. Crea recursos AWS: Thing, certificados X.509, política IoT
4. Configura endpoints en `.env`
5. Verifica que la red `keedian-network` exista
6. Levanta el contenedor `greengrass-core`
7. Espera que el Nucleus arranque (`Launched Nucleus successfully`)
8. Espera 30 segundos para la inicialización de los componentes
9. Verifica que los 6 componentes estén activos (sin errores `FATAL` en sus logs)

---

## Componentes desplegados

| Componente | Versión | Descripción |
|------------|---------|-------------|
| `com.keedian.config-manager` | 1.1.9 | Gestión de configuración del gateway |
| `com.keedian.db-layer` | 1.2.4 | Capa de acceso a PostgreSQL |
| `com.keedian.task-manager` | 1.1.8 | Orquestación de tareas |
| `com.keedian.modbus-adapter` | 1.3.2 | Lectura de dispositivos Modbus |
| `com.keedian.bacnet-adapter` | 1.1.6 | Lectura de dispositivos BACnet |
| `com.keedian.data-uploader` | 1.2.4 | Publicación de datos a AWS IoT Core |

Los componentes se registran en `config.yaml` al arrancar el contenedor mediante la lectura
de sus recetas JSON en `/keedian-components/<nombre>/recipes/<nombre>-<versión>.json`.
No se requiere `greengrass-cli` ni despliegues desde la nube.

---

## Levantar el proyecto (usos posteriores)

```bash
docker compose up -d
```

Verificar que el Nucleus arrancó:

```bash
docker logs greengrass-core | grep "Nucleus"
# Debe mostrar: "Launched Nucleus successfully."
```

> Los componentes se registran en `config.yaml` cada vez que el contenedor arranca.
> No requieren re-despliegue mientras el `.env` y los certificados en `config/` estén presentes.

---

## Bajar el proyecto

```bash
# Solo detener (los certificados y .env se conservan)
docker compose down

# Detener y limpiar volúmenes
# Los componentes se re-registran automáticamente al volver a levantar
docker compose down -v
```

---

## Ver logs de un componente

> En **Git Bash** y **PowerShell** es necesario `MSYS_NO_PATHCONV=1` para que Docker
> no convierta las rutas absolutas del contenedor.

```bash
# Seguir el log en tiempo real
MSYS_NO_PATHCONV=1 docker exec greengrass-core \
  tail -f /greengrass/v2/logs/com.keedian.config-manager.log

# Ver los últimos 100 líneas
MSYS_NO_PATHCONV=1 docker exec greengrass-core \
  sh -c "tail -100 /greengrass/v2/logs/com.keedian.modbus-adapter.log"

# Listar todos los logs disponibles
MSYS_NO_PATHCONV=1 docker exec greengrass-core \
  sh -c "ls /greengrass/v2/logs/"
```

---

## Verificar estado de los componentes

```bash
for comp in config-manager db-layer task-manager modbus-adapter bacnet-adapter data-uploader; do
  MSYS_NO_PATHCONV=1 docker exec greengrass-core \
    sh -c "grep -q FATAL /greengrass/v2/logs/com.keedian.${comp}.log 2>/dev/null \
           && echo '✗ FATAL' || echo '✓ OK'"
  echo "  → com.keedian.$comp"
done
```

---

## Troubleshooting rápido

| Síntoma | Solución |
|---------|---------|
| `La red keedian-network no existe` | Ejecutar primero `bash setup.sh` en el proyecto **keedian-link** |
| `KEEDIAN_LINK_COMPONENTS_PATH no detectado` | Definir en `.env` la ruta absoluta. En WSL: `/mnt/d/Keedian/.../keedian-link/components` |
| Rutas convertidas en Git Bash (`C:/Program Files/Git/greengrass/...`) | Prefija el comando con `MSYS_NO_PATHCONV=1` |
| `exec /entrypoint.sh failed: No such file or directory` | CRLF en entrypoint. `setup.sh` lo corrige automáticamente. Manual: `python3 -c "open('greengrass-core/entrypoint.sh','wb').write(open('greengrass-core/entrypoint.sh','rb').read().replace(b'\r\n',b'\n'))"` |
| Componente sin log tras 30s | El Nucleus aún está procesando. Espera y vuelve a verificar con `ls /greengrass/v2/logs/` |
| Componente con errores `FATAL` en log | Revisar log completo: `MSYS_NO_PATHCONV=1 docker exec greengrass-core sh -c "tail -100 /greengrass/v2/logs/com.keedian.<nombre>.log"` |
| Volumen con estado corrupto | `docker compose down -v && bash setup.sh` |
| `Not Authorized` en IPC (HelloWorld) | Verificar que `accessControl` en `entrypoint.sh` use `aws.greengrass#PublishToIoTCore` |
| `docker` no reconocido en PowerShell | Ejecutar como Administrador: `[System.Environment]::SetEnvironmentVariable('Path', [System.Environment]::GetEnvironmentVariable('Path','Machine') + ';C:\Program Files\Docker\Docker\resources\bin', 'Machine')` — reiniciar terminal |

---

> Para la guía completa de configuración ver [SETUP.md](SETUP.md)
