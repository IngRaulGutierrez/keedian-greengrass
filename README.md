# keedian-greengrass

AWS IoT Greengrass v2 corriendo en Docker Desktop (Windows), publicando mensajes Hello World a AWS IoT Core.

---

## Levantar el proyecto

```bash
docker compose up -d
```

Verificar que el Nucleus arrancó correctamente:

```bash
docker logs greengrass-core
# Debe mostrar: "Launched Nucleus successfully."
```

Una vez levantado, el componente `com.example.HelloWorld` comenzará a publicar automáticamente en el topic `hello/world` cada 5 segundos:

```json
{
  "message": "Hello World from Greengrass on Docker!",
  "count": 1,
  "timestamp": 1775269385.817
}
```

Para verificar los mensajes en AWS IoT Console:
1. Ir a **AWS IoT Console** — región **US East (Ohio) — us-east-2**
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
[HelloWorld] #1 Publicado en 'hello/world': Hello World from Greengrass on Docker!
[HelloWorld] #2 Publicado en 'hello/world': Hello World from Greengrass on Docker!
```

---

## Verificar conectividad con AWS IoT Core

```powershell
Test-NetConnection -ComputerName "akycruzqpng03-ats.iot.us-east-2.amazonaws.com" -Port 8883
# TcpTestSucceeded: True
```

---

## Troubleshooting rápido

| Síntoma | Solución |
|---------|---------|
| `docker` no reconocido en PowerShell | Abrir PowerShell **como Administrador** y ejecutar: `[System.Environment]::SetEnvironmentVariable('Path', [System.Environment]::GetEnvironmentVariable('Path', 'Machine') + ';C:\Program Files\Docker\Docker\resources\bin', 'Machine')` — luego reiniciar la terminal |
| `exec /entrypoint.sh failed: No such file or directory` | Archivo con saltos de línea Windows (CRLF). Ejecutar: `sed -i 's/\r//' greengrass-core/entrypoint.sh` y reconstruir |
| `dependencies is already a container` | Volumen con estado corrupto. Ejecutar: `docker compose down -v && docker compose up -d` |
| `Not Authorized` en IPC | Verificar que `accessControl` en `entrypoint.sh` use `aws.greengrass#PublishToIoTCore` (no `aws.greengrass.ipc.mqttproxy#...`) |
| Componente va a FINISHED sin ejecutar nada | Falta `lifecycle` en la sección del componente en `config.yaml` dentro del `entrypoint.sh` |
| Log del componente vacío aunque corre | Python bufferiza stdout. El script debe correr con `python3 -u` |

---

> Para la guía completa de configuración ver [SETUP.md](SETUP.md)
