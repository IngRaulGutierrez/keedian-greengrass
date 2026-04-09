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
