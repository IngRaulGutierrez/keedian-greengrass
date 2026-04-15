#!/bin/bash
# ============================================================
# simulate-modbus.sh — Simula lecturas del modbus-adapter
# Inserta directamente en la tabla outbox de PostgreSQL,
# replicando el resultado que produciría db-layer al recibir
# el mensaje IPC keedian/local/task/completed.
#
# NOTA: Greengrass IPC requiere SVCUID que solo el Nucleus
# inyecta a componentes hijos. docker exec no tiene ese token,
# por lo que la inserción directa en PostgreSQL es el método
# correcto para simular el flujo desde fuera del runtime.
# ============================================================
# Uso directo:   bash scripts/simulate-modbus.sh
# ============================================================

GATEWAY_ID="${THING_NAME:-GreengrassDockerCore}"
TASK_ID="sim_poll_$(date +%s)"
TIMESTAMP="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
TOPIC="keedian/${GATEWAY_ID}/telemetry"

echo "[simulate-modbus] Insertando lecturas en outbox..."
echo "[simulate-modbus] gateway_id=${GATEWAY_ID} | task_id=${TASK_ID} | topic=${TOPIC}"

docker exec keedian-gw-postgres psql -U keedian_gw -d keedian_gw -v ON_ERROR_STOP=1 -c "
INSERT INTO outbox
  (site_id, batch_id, device_id, point_id, value, quality, unit, timestamp, topic, status, retry_count, created_at)
VALUES
  ('${GATEWAY_ID}', '${TASK_ID}', 'sensor_1', 'temperature', 22.5,  'good', 'C',  '${TIMESTAMP}', '${TOPIC}', 'PENDING', 0, NOW()),
  ('${GATEWAY_ID}', '${TASK_ID}', 'sensor_1', 'humidity',    65.0,  'good', '%',  '${TIMESTAMP}', '${TOPIC}', 'PENDING', 0, NOW()),
  ('${GATEWAY_ID}', '${TASK_ID}', 'sensor_1', 'pressure',    1013.25, 'good', 'hPa', '${TIMESTAMP}', '${TOPIC}', 'PENDING', 0, NOW()),
  ('${GATEWAY_ID}', '${TASK_ID}', 'sensor_1', 'light',       0.0,   'good', 'lux', '${TIMESTAMP}', '${TOPIC}', 'PENDING', 0, NOW());
" && echo "[simulate-modbus] ✓ 4 lecturas insertadas en outbox (status=PENDING, topic=${TOPIC})" \
  || echo "[simulate-modbus] ERROR: fallo al insertar en outbox" >&2

echo ""
echo "[simulate-modbus] Verificar resultado:"
echo "  docker exec keedian-gw-postgres psql -U keedian_gw -d keedian_gw -c \"SELECT id, device_id, point_id, value, status, created_at FROM outbox ORDER BY created_at DESC LIMIT 10;\""
