#!/bin/bash
# ============================================================
# validate.sh — Validación de integración keedian-greengrass
# Compatible con Linux, macOS y Windows (Git Bash / MSYS2)
# ============================================================
# Uso: bash validate.sh
# ============================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

ok()   { echo -e "${GREEN}  ✓${NC} $1"; }
fail() { echo -e "${RED}  ✗${NC} $1"; ERRORS=$((ERRORS + 1)); }
warn() { echo -e "${YELLOW}  ?${NC} $1"; }
section() { echo -e "\n${CYAN}=== $1 ===${NC}"; }

ERRORS=0
export MSYS_NO_PATHCONV=1

# ------------------------------------------------------------
# 1. Contenedores activos
# ------------------------------------------------------------
section "1. Contenedores"

for name in greengrass-core keedian-gw-postgres tuten-gw-mqtt; do
    status=$(docker inspect --format '{{.State.Status}}' "$name" 2>/dev/null)
    if [ "$status" = "running" ]; then
        ok "$name → running"
    elif [ -z "$status" ]; then
        fail "$name → no existe"
    else
        fail "$name → $status"
    fi
done

# ------------------------------------------------------------
# 2. Red keedian-network
# ------------------------------------------------------------
section "2. Red keedian-network"

if docker network inspect keedian-network &>/dev/null; then
    containers=$(docker network inspect keedian-network \
        --format '{{range .Containers}}{{.Name}} {{end}}' 2>/dev/null)
    ok "keedian-network existe — contenedores: $containers"
else
    fail "keedian-network no existe — ejecuta setup.sh de keedian-link"
fi

# ------------------------------------------------------------
# 3. Conectividad TCP desde Greengrass
# ------------------------------------------------------------
section "3. Conectividad TCP desde greengrass-core"

check_tcp() {
    local host="$1"
    local port="$2"
    local label="$3"
    docker exec greengrass-core python3 -c "
import socket, sys
try:
    s = socket.create_connection(('$host', $port), timeout=5)
    s.close()
except Exception as e:
    print(str(e), file=sys.stderr)
    sys.exit(1)
" 2>/dev/null
    if [ $? -eq 0 ]; then
        ok "$label ($host:$port) → alcanzable"
    else
        fail "$label ($host:$port) → no alcanzable"
    fi
}

check_tcp "keedian-gw-postgres" 5432 "PostgreSQL"
check_tcp "tuten-gw-mqtt"       1883 "Mosquitto MQTT"

# ------------------------------------------------------------
# 4. Estado de los componentes keedian-link
# ------------------------------------------------------------
section "4. Componentes keedian-link"

COMPONENTS=(
    "config-manager"
    "db-layer"
    "task-manager"
    "modbus-adapter"
    "bacnet-adapter"
    "data-uploader"
)

for comp in "${COMPONENTS[@]}"; do
    log="/greengrass/v2/logs/com.keedian.${comp}.log"
    if docker exec greengrass-core sh -c "test -f $log" 2>/dev/null; then
        if docker exec greengrass-core sh -c "grep -q FATAL $log" 2>/dev/null; then
            fail "com.keedian.$comp → errores FATAL en log"
        else
            lines=$(docker exec greengrass-core sh -c "wc -l < $log" 2>/dev/null)
            ok "com.keedian.$comp → sin errores FATAL ($lines líneas)"
        fi
    else
        warn "com.keedian.$comp → log no disponible aún"
    fi
done

# ------------------------------------------------------------
# 5. config-manager — arranque correcto
# ------------------------------------------------------------
section "5. config-manager — arranque correcto"

cm_log="/greengrass/v2/logs/com.keedian.config-manager.log"
if docker exec greengrass-core sh -c "test -f $cm_log" 2>/dev/null; then
    check_log_pattern() {
        local pattern="$1"
        local label="$2"
        if docker exec greengrass-core sh -c "grep -q '$pattern' $cm_log" 2>/dev/null; then
            ok "config-manager → $label"
        else
            fail "config-manager → $label (no encontrado en log)"
        fi
    }

    check_log_pattern "Connected to Greengrass IPC"       "Connected to Greengrass IPC"
    check_log_pattern "Configuration loaded and published" "Config loaded successfully"
    check_log_pattern "Published to IPC"                   "Published to IPC (keedian/local/config/active)"

    if docker exec greengrass-core sh -c "grep -q 'ModuleNotFoundError' $cm_log" 2>/dev/null; then
        fail "config-manager → ModuleNotFoundError detectado (venv no estaba listo al arrancar)"
        echo "     Fix: bash setup.sh  — reconstruye la imagen con el nuevo entrypoint.sh"
    fi
else
    warn "config-manager → log no disponible aún"
fi

# ------------------------------------------------------------
# 6. HelloWorld
# ------------------------------------------------------------
section "6. Componente HelloWorld"

hw_log="/greengrass/v2/logs/com.example.HelloWorld.log"
if docker exec greengrass-core sh -c "test -f $hw_log" 2>/dev/null; then
    if docker exec greengrass-core sh -c "grep -q FATAL $hw_log" 2>/dev/null; then
        fail "com.example.HelloWorld → errores FATAL en log"
    else
        ok "com.example.HelloWorld → sin errores FATAL"
        last=$(docker exec greengrass-core sh -c "tail -1 $hw_log" 2>/dev/null)
        echo "     Última línea: $last"
    fi
else
    warn "com.example.HelloWorld → log no disponible aún"
fi

# ------------------------------------------------------------
# 6. Nucleus
# ------------------------------------------------------------
section "7. Nucleus Greengrass"

if docker logs greengrass-core 2>&1 | grep -q "Launched Nucleus successfully"; then
    ok "Nucleus arrancado correctamente"
else
    fail "Nucleus no reportó inicio exitoso"
fi

nucleus_errors=$(docker logs greengrass-core 2>&1 | grep -c "FATAL" || true)
if [ "$nucleus_errors" -gt 0 ]; then
    warn "El log del contenedor tiene $nucleus_errors líneas con FATAL"
fi

# ------------------------------------------------------------
# Resumen
# ------------------------------------------------------------
echo ""
echo "============================================================"
if [ "$ERRORS" -eq 0 ]; then
    echo -e "${GREEN}[validate] Todo OK — integración verificada correctamente.${NC}"
else
    echo -e "${RED}[validate] $ERRORS error(es) encontrado(s). Revisa los puntos marcados con ✗.${NC}"
    echo ""
    echo "Comandos útiles para diagnosticar:"
    echo "  docker logs greengrass-core | tail -50"
    echo "  MSYS_NO_PATHCONV=1 docker exec greengrass-core sh -c \"tail -50 /greengrass/v2/logs/com.keedian.<nombre>.log\""
fi
echo "============================================================"

exit $ERRORS
