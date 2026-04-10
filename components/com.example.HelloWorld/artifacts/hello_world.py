import awsiot.greengrasscoreipc
from awsiot.greengrasscoreipc.model import (
    PublishToIoTCoreRequest,
    QOS
)
import time
import json
import os

TOPIC = "hello/world"
TIMEOUT = 10

device_name = os.getenv("DEVICE_NAME")
base_message = "Hello World from Greengrass on Docker!"
full_message = f"{base_message} - {device_name}" if device_name else base_message

print("[HelloWorld] Conectando al IPC de Greengrass...")
ipc_client = awsiot.greengrasscoreipc.connect()
print("[HelloWorld] Conectado. Iniciando publicación de mensajes...")

count = 1
while True:
    message = {
        "message": full_message,
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
