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
docker compose down
```

---

## Ver logs del componente

```bash
MSYS_NO_PATHCONV=1 docker exec greengrass-core \
  tail -f /greengrass/v2/logs/com.example.HelloWorld.log
```

---

> Para la guía completa de configuración ver [SETUP.md](SETUP.md)
