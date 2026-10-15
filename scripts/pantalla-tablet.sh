#!/bin/bash
# ==============================================================================
# pantalla-tablet - Utilidad de usuario para la pantalla extendida Galaxy Tab S9 FE
# ==============================================================================

PROJECT_DIR="/home/jose/ArchivoPortable/03_Desarrollo/Proyectos/Pantalla_Tablet"
CACHE_DIR="$HOME/.cache/pantalla-tablet"
PID_FILE="$CACHE_DIR/wayvnc.pid"
WATCHDOG_PID_FILE="$CACHE_DIR/watchdog.pid"
STOPPING_FLAG="$CACHE_DIR/stopping.flag"
LOG_FILE="$CACHE_DIR/wayvnc.log"
WATCHDOG_LOG="$CACHE_DIR/watchdog.log"
PORT="${PANTALLA_TABLET_PORT:-5910}"
MONITOR="TABLET"
PC_TAILSCALE_IP="100.65.222.39"
TAB_TAILSCALE_IP="100.105.161.7"

mkdir -p "$CACHE_DIR"

# ------------------------------------------------------------------------------
# Funciones auxiliares
# ------------------------------------------------------------------------------

is_tablet_monitor_active() {
    hyprctl monitors -j 2>/dev/null | grep -q '"name": "'"$MONITOR"'"'
}

is_wayvnc_running() {
    if [ -f "$PID_FILE" ]; then
        local pid
        pid=$(cat "$PID_FILE" 2>/dev/null)
        if [ -n "$pid" ] && [ -d "/proc/$pid" ]; then
            local cmdline
            cmdline=$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null)
            if [[ "$cmdline" == *"wayvnc"* ]] && [[ "$cmdline" == *"-o $MONITOR"* ]] && [[ "$cmdline" == *"0.0.0.0"* ]] && [[ "$cmdline" == *"$PORT"* ]]; then
                echo "$pid"
                return 0
            fi
        fi
        rm -f "$PID_FILE"
    fi
    local found_pid
    found_pid=$(pgrep -f "wayvnc -o $MONITOR.*0.0.0.0 $PORT" | head -n 1)
    if [ -n "$found_pid" ]; then
        echo "$found_pid" > "$PID_FILE"
        echo "$found_pid"
        return 0
    fi
    return 1
}

is_watchdog_running() {
    if [ -f "$WATCHDOG_PID_FILE" ]; then
        local wpid
        wpid=$(cat "$WATCHDOG_PID_FILE" 2>/dev/null)
        if [ -n "$wpid" ] && [ -d "/proc/$wpid" ]; then
            echo "$wpid"
            return 0
        fi
        rm -f "$WATCHDOG_PID_FILE"
    fi
    return 1
}

is_adb_device_connected() {
    adb devices 2>/dev/null | grep -v "List of devices" | grep -E '\bdevice\b' | grep -q .
}

is_samsung_usb_plugged() {
    lsusb 2>/dev/null | grep -qiE '04e8:|Samsung'
}

get_tablet_serial() {
    local serials
    serials=$(adb devices 2>/dev/null | grep -v "List of devices" | grep -E '\bdevice\b' | awk '{print $1}')
    local count
    count=$(echo "$serials" | grep -c . 2>/dev/null || echo 0)
    if [ "$count" -le 1 ]; then
        echo "$serials"
        return 0
    fi
    for s in $serials; do
        local model
        model=$(adb -s "$s" shell getprop ro.product.model 2>/dev/null | tr -d '\r')
        if [[ "$model" == *"X510"* ]] || [[ "$model" == *"Tab"* ]] || [[ "$s" == "R52X90CGTXJ" ]]; then
            echo "$s"
            return 0
        fi
    done
    echo "$serials" | head -n 1
}

ensure_adb_connection() {
    if is_adb_device_connected; then
        return 0
    fi

    if is_samsung_usb_plugged; then
        echo "[INFO] Dispositivo Samsung detectado en bus USB. Sincronizando servicio ADB..."
    fi

    adb start-server > /dev/null 2>&1
    adb reconnect > /dev/null 2>&1

    local count=0
    while [ $count -lt 3 ]; do
        if is_adb_device_connected; then
            return 0
        fi
        sleep 0.5
        (( count++ ))
    done

    if is_samsung_usb_plugged && ! is_adb_device_connected; then
        adb kill-server > /dev/null 2>&1
        adb start-server > /dev/null 2>&1
        sleep 0.8
        if is_adb_device_connected; then
            return 0
        fi
    fi

    return 1
}

is_adb_reverse_active() {
    local target_serial="$1"
    if [ -n "$target_serial" ]; then
        adb -s "$target_serial" reverse --list 2>/dev/null | grep -q "tcp:$PORT"
    else
        adb reverse --list 2>/dev/null | grep -q "tcp:$PORT"
    fi
}

check_vnc_handshake() {
    if ss -ltnp 2>/dev/null | grep -q ":$PORT\b"; then
        return 0
    fi
    return 1
}

# Obtiene el workspace activo actual de eDP-1 vía hyprctl.
get_edp1_active_workspace() {
    local ws_id
    ws_id=$(hyprctl monitors -j 2>/dev/null | jq -r '.[] | select(.name=="eDP-1") | .activeWorkspace.id' 2>/dev/null)
    if [ -z "$ws_id" ] || [ "$ws_id" = "null" ]; then
        return 1
    fi
    echo "$ws_id"
}

# Verifica si un workspace con ID dado existe actualmente en el compositor.
workspace_exists() {
    local ws_id="$1"
    hyprctl workspaces -j 2>/dev/null | jq -e --argjson id "$ws_id" '.[] | select(.id==$id)' > /dev/null 2>&1
}

# Verifica si un workspace con ID dado está actualmente asignado a TABLET.
workspace_is_on_tablet() {
    local ws_id="$1"
    hyprctl workspaces -j 2>/dev/null | jq -e --argjson id "$ws_id" '.[] | select(.id==$id and .monitor=="'"$MONITOR"'")' > /dev/null 2>&1
}

# Wrappers de dispatchers usando la API Lua de Hyprland 0.56.2
hypr_moveworkspace() {
    hyprctl eval "hl.dispatch(hl.dsp.workspace.move({ workspace = \"$1\", monitor = \"$2\" }))" > /dev/null 2>&1
}

hypr_focusmonitor() {
    hyprctl eval "hl.dispatch(hl.dsp.focus({ monitor = \"$1\" }))" > /dev/null 2>&1
}

hypr_workspace() {
    hyprctl eval "hl.dispatch(hl.dsp.focus({ workspace = \"$1\" }))" > /dev/null 2>&1
}

# ------------------------------------------------------------------------------
# Asignación de workspace a TABLET
# ------------------------------------------------------------------------------

assign_workspace_to_tablet() {
    local target_ws="$1"

    local tablet_ws_list
    tablet_ws_list=$(hyprctl workspaces -j 2>/dev/null | jq -r '.[] | select(.monitor=="'"$MONITOR"'") | .id' 2>/dev/null)
    for ws_id in $tablet_ws_list; do
        if [ -n "$ws_id" ] && [ "$ws_id" != "null" ] && [ "$ws_id" != "$target_ws" ]; then
            echo "[INFO] Evacuando workspace residual WS$ws_id de $MONITOR a eDP-1..."
            hypr_moveworkspace "$ws_id" "eDP-1"
            sleep 0.1
        fi
    done

    if workspace_is_on_tablet "$target_ws"; then
        echo "[INFO] WS$target_ws ya está asignado a $MONITOR."
        hypr_focusmonitor "$MONITOR"
        sleep 0.1
        hypr_workspace "$target_ws"
        sleep 0.1
        hypr_focusmonitor "eDP-1"
        return 0
    fi

    if workspace_exists "$target_ws"; then
        echo "[INFO] WS$target_ws existe. Trasladando a $MONITOR..."
        hypr_moveworkspace "$target_ws" "$MONITOR"
        sleep 0.25
        hypr_focusmonitor "$MONITOR"
        sleep 0.15
        hypr_workspace "$target_ws"
        sleep 0.15
    else
        echo "[INFO] WS$target_ws no existe. Creándolo en $MONITOR..."
        hypr_focusmonitor "$MONITOR"
        sleep 0.15
        hypr_workspace "$target_ws"
        sleep 0.15
    fi

    hypr_focusmonitor "eDP-1"
}

# ------------------------------------------------------------------------------
# Servicio Watchdog (supervisión asíncrona de WayVNC)
# ------------------------------------------------------------------------------

cmd_watchdog() {
    local target_pid="$1"
    if [ -z "$target_pid" ]; then
        exit 1
    fi

    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Watchdog iniciado para WayVNC PID $target_pid" >> "$WATCHDOG_LOG"

    while [ -d "/proc/$target_pid" ]; do
        sleep 1.5
    done

    # Verificación de detención intencional
    if [ -f "$STOPPING_FLAG" ]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] WayVNC PID $target_pid terminó por stop intencional. Saliendo watchdog." >> "$WATCHDOG_LOG"
        rm -f "$WATCHDOG_PID_FILE"
        exit 0
    fi

    # Muerte inesperada detectada (crash)
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ALERTA: Muerte inesperada de WayVNC PID $target_pid. Ejecutando cleanup automático..." >> "$WATCHDOG_LOG"

    # Clean ADB reverse
    if is_adb_reverse_active; then
        adb reverse --remove tcp:"$PORT" > /dev/null 2>&1 || true
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] Regla ADB reverse removida por watchdog." >> "$WATCHDOG_LOG"
    fi

    # Clean TABLET monitor de Hyprland
    if is_tablet_monitor_active; then
        local tablet_ws_list
        tablet_ws_list=$(hyprctl workspaces -j 2>/dev/null | jq -r '.[] | select(.monitor=="'"$MONITOR"'") | .id' 2>/dev/null)
        for ws_id in $tablet_ws_list; do
            if [ -n "$ws_id" ] && [ "$ws_id" != "null" ]; then
                hypr_moveworkspace "$ws_id" "eDP-1"
                sleep 0.1
            fi
        done
        hyprctl output remove "$MONITOR" > /dev/null 2>&1 || true
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] Monitor $MONITOR evacuado y eliminado de Hyprland por watchdog. Workspaces restaurados a eDP-1." >> "$WATCHDOG_LOG"
    fi

    rm -f "$PID_FILE" "$WATCHDOG_PID_FILE"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Cleanup de watchdog completado." >> "$WATCHDOG_LOG"
}

# ------------------------------------------------------------------------------
# Comandos principales
# ------------------------------------------------------------------------------

cmd_start() {
    local target_ws_arg="$1"

    # Eliminar flag de stop residual si existía
    rm -f "$STOPPING_FLAG"

    # Validación del argumento N
    local target_ws=""
    if [ -n "$target_ws_arg" ]; then
        if ! [[ "$target_ws_arg" =~ ^[1-9][0-9]*$ ]]; then
            echo "ERROR: Argumento inválido para 'start': '$target_ws_arg'" >&2
            echo "       El workspace debe ser un entero positivo (ej: 1, 2, 7, 99)." >&2
            echo "Uso: pantalla-tablet start [N]" >&2
            exit 1
        fi
        target_ws="$target_ws_arg"
    fi

    echo "=== Iniciando servicio pantalla-tablet ==="

    # Determinar N
    local original_edp1_ws
    original_edp1_ws=$(get_edp1_active_workspace)
    if [ $? -ne 0 ] || [ -z "$original_edp1_ws" ]; then
        echo "ERROR: No se puede determinar el workspace activo de eDP-1." >&2
        echo "       Verifique que Hyprland esté ejecutándose y eDP-1 esté disponible." >&2
        exit 1
    fi

    if [ -z "$target_ws" ]; then
        target_ws="$original_edp1_ws"
        echo "[INFO] Workspace objetivo (autodetectado de eDP-1): WS$target_ws"
    else
        echo "[INFO] Workspace objetivo (explícito): WS$target_ws"
        echo "[INFO] Workspace activo actual de eDP-1: WS$original_edp1_ws"
    fi

    local created_new_monitor=0

    # 1. Asegurar monitor TABLET
    if is_tablet_monitor_active; then
        echo "[INFO] Monitor $MONITOR ya se encuentra activo en Hyprland."
    else
        echo "[INFO] Creando monitor virtual $MONITOR en Hyprland..."
        hyprctl output create headless "$MONITOR" > /dev/null 2>&1
        created_new_monitor=1

        local count=0
        until is_tablet_monitor_active; do
            sleep 0.2
            (( count++ ))
            if [ $count -ge 5 ]; then
                echo "ERROR: No se pudo verificar la creación del monitor $MONITOR en Hyprland." >&2
                exit 1
            fi
        done

        echo "[OK] Monitor $MONITOR creado exitosamente."
        echo "[INFO] Aplicando geometría 1920x1080@60 en x=1920..."
        hyprctl keyword monitor "$MONITOR,1920x1080@60,1920x0,1" > /dev/null 2>&1
        sleep 0.2
    fi

    # 2. Asignar workspace N a TABLET
    assign_workspace_to_tablet "$target_ws"

    if workspace_is_on_tablet "$target_ws"; then
        echo "[OK] WS$target_ws asignado a $MONITOR como workspace activo."
    else
        echo "[ADVERTENCIA] No se pudo verificar que WS$target_ws quedó activo en $MONITOR."
    fi

    hypr_focusmonitor "eDP-1"

    # 3. Comprobar / Iniciar WayVNC
    local existing_pid
    if existing_pid=$(is_wayvnc_running); then
        echo "[INFO] WayVNC ya se encuentra ejecutándose con PID $existing_pid."
    else
        echo "[INFO] Iniciando servidor WayVNC sobre $MONITOR (con --render-cursor)..."
        setsid wayvnc -o "$MONITOR" -g -r -f 60 --log-level=debug 0.0.0.0 "$PORT" < /dev/null > "$LOG_FILE" 2>&1 &
        local new_pid=$!
        echo "$new_pid" > "$PID_FILE"
        sleep 1.2

        if [ -n "$new_pid" ] && [ -d "/proc/$new_pid" ]; then
            echo "[OK] WayVNC iniciado con PID $new_pid en 0.0.0.0:$PORT."
        else
            echo "ERROR: No se pudo iniciar el proceso WayVNC." >&2
            cat "$LOG_FILE" >&2
            rm -f "$PID_FILE"
            if [ $created_new_monitor -eq 1 ] && is_tablet_monitor_active; then
                echo "[ROLLBACK] Evacuando y eliminando monitor $MONITOR tras fallo de WayVNC..."
                local tablet_ws_list
                tablet_ws_list=$(hyprctl workspaces -j 2>/dev/null | jq -r '.[] | select(.monitor=="'"$MONITOR"'") | .id' 2>/dev/null)
                for ws_id in $tablet_ws_list; do
                    if [ -n "$ws_id" ] && [ "$ws_id" != "null" ]; then
                        hypr_moveworkspace "$ws_id" "eDP-1"
                        sleep 0.1
                    fi
                done
                hyprctl output remove "$MONITOR" > /dev/null 2>&1
            fi
            exit 1
        fi
    fi

    # 4. Iniciar Watchdog de supervisión
    local current_wayvnc_pid
    current_wayvnc_pid=$(cat "$PID_FILE" 2>/dev/null)
    if [ -n "$current_wayvnc_pid" ] && [ -d "/proc/$current_wayvnc_pid" ]; then
        local wpid
        if wpid=$(is_watchdog_running); then
            echo "[INFO] Watchdog ya activo con PID $wpid."
        else
            setsid "$0" watchdog "$current_wayvnc_pid" > "$WATCHDOG_LOG" 2>&1 &
            local new_wpid=$!
            echo "$new_wpid" > "$WATCHDOG_PID_FILE"
            echo "[OK] Watchdog de supervisión iniciado (PID $new_wpid)."
        fi
    fi

    # 5. Comprobar ADB USB y establecer túnel
    if ensure_adb_connection; then
        local tablet_serial
        tablet_serial=$(get_tablet_serial)
        local adb_cmd="adb"
        if [ -n "$tablet_serial" ]; then
            adb_cmd="adb -s $tablet_serial"
            echo "[INFO] Tablet detectada por USB (ADB device: $tablet_serial)."
        else
            echo "[INFO] Tablet detectada por USB (ADB device)."
        fi

        if ! is_adb_reverse_active "$tablet_serial"; then
            echo "[INFO] Estableciendo túnel ADB reverse tcp:$PORT tcp:$PORT..."
            $adb_cmd reverse tcp:"$PORT" tcp:"$PORT" > /dev/null 2>&1
        fi

        if is_adb_reverse_active "$tablet_serial"; then
            echo "[OK] Túnel ADB reverse activo (tcp:$PORT tcp:$PORT)."
        else
            echo "[ADVERTENCIA] No se pudo establecer la regla ADB reverse." >&2
        fi
    else
        echo "[INFO] Tablet no detectada por USB (ADB). WayVNC permanece activo para transporte por Tailscale ($PC_TAILSCALE_IP:$PORT)."
    fi

    # 6. Verificación de Handshake VNC
    if check_vnc_handshake; then
        echo "[OK] Handshake VNC verificado en 127.0.0.1:$PORT (RFB 003.008)."
    else
        echo "[ADVERTENCIA] No se pudo verificar la respuesta RFB en 127.0.0.1:$PORT."
    fi

    echo "=== Servicio iniciado correctamente ==="
}

cmd_stop() {
    echo "=== Deteniendo servicio pantalla-tablet ==="

    touch "$STOPPING_FLAG"

    local wpid
    if wpid=$(is_watchdog_running); then
        echo "[INFO] Deteniendo watchdog de supervisión (PID $wpid)..."
        kill "$wpid" 2>/dev/null || true
        rm -f "$WATCHDOG_PID_FILE"
    fi

    local tablet_serial
    tablet_serial=$(get_tablet_serial)
    local adb_cmd="adb"
    if [ -n "$tablet_serial" ]; then
        adb_cmd="adb -s $tablet_serial"
    fi

    if is_adb_reverse_active "$tablet_serial"; then
        echo "[INFO] Removiendo regla ADB reverse para puerto $PORT..."
        $adb_cmd reverse --remove tcp:"$PORT" > /dev/null 2>&1
        if ! is_adb_reverse_active "$tablet_serial"; then
            echo "[OK] Regla ADB reverse removida."
        else
            echo "[ADVERTENCIA] No se pudo remover la regla ADB reverse." >&2
        fi
    else
        echo "[INFO] No hay regla ADB reverse activa para puerto $PORT."
    fi

    if [ -f "$PID_FILE" ]; then
        local pid
        pid=$(cat "$PID_FILE" 2>/dev/null)
        if [ -n "$pid" ] && [ -d "/proc/$pid" ]; then
            echo "[INFO] Deteniendo proceso WayVNC (PID $pid)..."
            kill "$pid" 2>/dev/null
            sleep 0.8
            if [ -d "/proc/$pid" ]; then
                kill -9 "$pid" 2>/dev/null
            fi
            echo "[OK] Proceso WayVNC detenido."
        else
            echo "[INFO] No se encontró proceso WayVNC activo con PID $pid."
        fi
        rm -f "$PID_FILE"
    else
        local found_pid
        found_pid=$(pgrep -f "wayvnc -o $MONITOR.*0.0.0.0 $PORT" | head -n 1)
        if [ -n "$found_pid" ]; then
            echo "[INFO] Deteniendo proceso WayVNC huérfano (PID $found_pid)..."
            kill "$found_pid" 2>/dev/null
            sleep 0.8
            if [ -d "/proc/$found_pid" ]; then
                kill -9 "$found_pid" 2>/dev/null
            fi
            echo "[OK] Proceso WayVNC detenido."
        else
            echo "[INFO] Ningún proceso WayVNC activo para $MONITOR."
        fi
    fi

    if is_tablet_monitor_active; then
        echo "[INFO] Evacuando workspaces de $MONITOR a eDP-1..."
        local tablet_ws_list
        tablet_ws_list=$(hyprctl workspaces -j 2>/dev/null | jq -r '.[] | select(.monitor=="'"$MONITOR"'") | .id' 2>/dev/null)
        for ws_id in $tablet_ws_list; do
            if [ -n "$ws_id" ] && [ "$ws_id" != "null" ]; then
                echo "[INFO] Reasignando WS$ws_id de $MONITOR a eDP-1..."
                hypr_moveworkspace "$ws_id" "eDP-1"
                sleep 0.1
            fi
        done

        local remaining_ws
        remaining_ws=$(hyprctl workspaces -j 2>/dev/null | jq -r '.[] | select(.monitor=="'"$MONITOR"'") | .id' 2>/dev/null)
        if [ -n "$remaining_ws" ]; then
            echo "[ADVERTENCIA] Aún existen workspaces asignados a $MONITOR: $remaining_ws" >&2
        else
            echo "[OK] Todos los workspaces fueron reasignados a eDP-1."
        fi

        echo "[INFO] Eliminando monitor virtual $MONITOR de Hyprland..."
        hyprctl output remove "$MONITOR" > /dev/null 2>&1
        sleep 0.3
        if ! is_tablet_monitor_active; then
            echo "[OK] Monitor $MONITOR eliminado de Hyprland. Cursor limitado a eDP-1."
        else
            echo "[ADVERTENCIA] No se pudo remover el monitor $MONITOR." >&2
        fi
    else
        echo "[INFO] El monitor $MONITOR no estaba activo."
    fi

    rm -f "$STOPPING_FLAG" "$PID_FILE" "$WATCHDOG_PID_FILE"
    echo "=== Servicio detenido correctamente ==="
}

cmd_status() {
    echo "=== Estado de pantalla-tablet ==="

    if is_tablet_monitor_active; then
        echo "- Monitor $MONITOR: ACTIVO"
        local tablet_ws
        tablet_ws=$(hyprctl monitors -j 2>/dev/null | jq -r '.[] | select(.name=="'"$MONITOR"'") | .activeWorkspace.id' 2>/dev/null)
        if [ -n "$tablet_ws" ] && [ "$tablet_ws" != "null" ]; then
            echo "  - Workspace activo: WS$tablet_ws"
        fi
    else
        echo "- Monitor $MONITOR: INACTIVO"
    fi

    local pid
    if pid=$(is_wayvnc_running); then
        echo "- WayVNC: ACTIVO (PID $pid)"
        echo "  - Listener: 0.0.0.0:$PORT"
        echo "  - Comando: wayvnc -o $MONITOR -g -r -f 60 --log-level=debug 0.0.0.0 $PORT"
    else
        echo "- WayVNC: INACTIVO"
    fi

    local wpid
    if wpid=$(is_watchdog_running); then
        echo "- Watchdog de supervisión: ACTIVO (PID $wpid)"
    else
        echo "- Watchdog de supervisión: INACTIVO"
    fi

    if is_adb_device_connected; then
        local dev_id
        dev_id=$(get_tablet_serial)
        echo "- ADB USB: CONECTADO (Dispositivo: $dev_id)"
        if is_adb_reverse_active "$dev_id"; then
            echo "- ADB Reverse: ACTIVO (UsbFfs tcp:$PORT tcp:$PORT)"
        else
            echo "- ADB Reverse: INACTIVO"
        fi
    else
        echo "- ADB USB: NO CONECTADO"
        echo "- ADB Reverse: INACTIVO"
    fi

    echo "- IP Tailscale PC: $PC_TAILSCALE_IP"
    echo "- IP Tailscale Tablet: $TAB_TAILSCALE_IP"
    if command -v tailscale > /dev/null 2>&1; then
        if tailscale status 2>/dev/null | grep -q "$TAB_TAILSCALE_IP"; then
            echo "- Estado Tailscale Tablet: ONLINE / REGISTRADO"
        else
            echo "- Estado Tailscale Tablet: OFFLINE / NO REGISTRADO"
        fi
    else
        echo "- Estado Tailscale: Cliente no disponible"
    fi

    echo "================================="
}

case "$1" in
    start)
        cmd_start "$2"
        ;;
    stop)
        cmd_stop
        ;;
    status)
        cmd_status
        ;;
    watchdog)
        cmd_watchdog "$2"
        ;;
    *)
        echo "Uso: pantalla-tablet {start [N]|stop|status}" >&2
        exit 1
        ;;
esac
