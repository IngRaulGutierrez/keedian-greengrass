# keedian-greengrass

AWS IoT Greengrass v2 corriendo en Docker Desktop (Windows), publicando mensajes Hello World a AWS IoT Core.

---

## Primera vez (configuración automática)

1. Copia el archivo de ejemplo y completa tus credenciales:

```bash
cp .env.example .env
```

Edita `.env` con tus valores:

| Variable | Descripción |
|----------|-------------|
| `AWS_ACCESS_KEY_ID` | Access key del usuario IAM |
| `AWS_SECRET_ACCESS_KEY` | Secret key del usuario IAM |
| `AWS_REGION` | Región AWS (ej: `us-east-2`) |
| `DEVICE_NAME` | Nombre que aparece en el mensaje MQTT |
| `THING_NAME` | Nombre del Thing en AWS IoT Core |
| `IOT_DATA_ENDPOINT` | **Se completa automáticamente** |
| `IOT_CRED_ENDPOINT` | **Se completa automáticamente** |

2. Ejecuta el setup:

```bash
bash setup.sh
```

El script crea todos los recursos AWS necesarios (Thing, certificados, política IoT),
configura los endpoints en `.env` y levanta el contenedor listo para publicar mensajes.

---

## Levantar el proyecto (usos posteriores)

```bash
docker compose up -d
```

Verificar que el Nucleus arrancó correctamente:

```bash
docker logs greengrass-core
# Debe mostrar: "Launched Nucleus successfully."
```

Una vez levantado, el componente `com.example.HelloWorld` comenzará a publicar
automáticamente en el topic `hello/world` cada 5 segundos:

```json
{
  "message": "Hello World from Greengrass on Docker! - NombreDispositivo",
  "count": 1,
  "timestamp": 1775269385.817
}
```

Para verificar los mensajes en AWS IoT Console:
1. Ir a **AWS IoT Console** — verificar la región configurada en `.env`
2. Navegar a **Probar → Cliente de prueba de MQTT**
3. Suscribirse al topic: `hello/world`

---

## Bajar el proyecto

```bash
# Solo detener
docker compose down

# Detener y limpiar volúmenes (necesario si hay errores de estado corrupto)
docker compose down -v
```

---

## Ver logs del componente

```bash
MSYS_NO_PATHCONV=1 docker exec greengrass-core \
  tail -f /greengrass/v2/logs/com.example.HelloWorld.log
```

Resultado esperado:
```
[HelloWorld] Conectando al IPC de Greengrass...
[HelloWorld] Conectado. Iniciando publicación de mensajes...
[HelloWorld] #1 Publicado en 'hello/world': Hello World from Greengrass on Docker! - NombreDispositivo
[HelloWorld] #2 Publicado en 'hello/world': Hello World from Greengrass on Docker! - NombreDispositivo
```

---

## Troubleshooting rápido

| Síntoma | Solución |
|---------|---------|
| `docker` no reconocido en PowerShell | Abrir PowerShell **como Administrador** y ejecutar: `[System.Environment]::SetEnvironmentVariable('Path', [System.Environment]::GetEnvironmentVariable('Path', 'Machine') + ';C:\Program Files\Docker\Docker\resources\bin', 'Machine')` — luego reiniciar la terminal |
| `exec /entrypoint.sh failed: No such file or directory` | CRLF en entrypoint. El `setup.sh` lo corrige automáticamente. Si ocurre manualmente: `sed -i 's/\r//' greengrass-core/entrypoint.sh` |
| Volumen con estado corrupto | Ejecutar: `docker compose down -v && docker compose up -d` |
| `Not Authorized` en IPC | Verificar que `accessControl` en `entrypoint.sh` use `aws.greengrass#PublishToIoTCore` |
| Log del componente vacío aunque corre | Python bufferiza stdout. El script corre con `python3 -u` (ya configurado) |

---

> Para la guía completa de configuración ver [SETUP.md](SETUP.md)
