#!/usr/bin/env bash
# Virtual Sway output streamed to an Android VNC client (USB via ADB reverse).
set -u

CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/pantalla-tablet"
PID_FILE="$CACHE_DIR/wayvnc.pid"
OUTPUT_FILE="$CACHE_DIR/output"
PORT="${PANTALLA_TABLET_PORT:-5910}"
OUTPUT_PREFIX="HEADLESS-"
MAIN_OUTPUT="eDP-1"
WIDTH="${PANTALLA_TABLET_WIDTH:-1920}"
HEIGHT="${PANTALLA_TABLET_HEIGHT:-1200}"

mkdir -p "$CACHE_DIR"

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "Falta '$1'. Instálalo antes de continuar."; }

outputs_json() { swaymsg -r -t get_outputs 2>/dev/null; }
output_exists() { outputs_json | jq -e --arg name "$1" '.[] | select(.name == $name and .active == true)' >/dev/null; }
headless_outputs() { outputs_json | jq -r --arg prefix "$OUTPUT_PREFIX" '.[] | select(.active == true and (.name | startswith($prefix))) | .name'; }

adb_device() {
    adb devices 2>/dev/null | awk 'NR > 1 && $2 == "device" { print $1; exit }'
}

cmd_start() {
    need swaymsg
    need jq
    need wayvnc
    swaymsg -t get_version >/dev/null 2>&1 || die "No se puede hablar con Sway. Ejecuta esto dentro de tu sesión gráfica."
    output_exists "$MAIN_OUTPUT" || die "No encuentro la pantalla principal '$MAIN_OUTPUT'."

    local target_ws="${1:-$(swaymsg -t get_workspaces -r | jq -r '.[] | select(.focused) | .name')}"
    [[ "$target_ws" =~ ^[1-9][0-9]*$ ]] || die "Workspace inválido: '$target_ws'. Uso: pantalla-tablet start [N]"

    local output=""
    if [[ -f "$OUTPUT_FILE" ]]; then
        output=$(<"$OUTPUT_FILE")
        output_exists "$output" || output=""
    fi
    if [[ -z "$output" ]]; then
        local before after candidate
        before=$(headless_outputs)
        swaymsg create_output >/dev/null || die "Sway no pudo crear una salida headless."
        for _ in {1..30}; do
            after=$(headless_outputs)
            while IFS= read -r candidate; do
                [[ -n "$candidate" ]] || continue
                if ! printf '%s\n' "$before" | grep -Fxq "$candidate"; then
                    output="$candidate"
                    break
                fi
            done <<< "$after"
            [[ -n "$output" ]] && break
            sleep 0.1
        done
        [[ -n "$output" ]] || die "Sway creó la salida pero no pude identificarla. Revisa 'swaymsg -t get_outputs'."
        printf '%s\n' "$output" > "$OUTPUT_FILE"
    fi

    local main_width
    main_width=$(outputs_json | jq -r --arg name "$MAIN_OUTPUT" '.[] | select(.name == $name) | .current_mode.width' | head -n 1)
    [[ "$main_width" =~ ^[0-9]+$ ]] || main_width=1366
    swaymsg "output $output mode ${WIDTH}x${HEIGHT} position $main_width 0 scale 1" >/dev/null || die "No pude configurar $output."
    swaymsg "workspace number $target_ws; move workspace to output $output; workspace number $target_ws" >/dev/null || die "No pude asignar el workspace $target_ws."
    swaymsg "focus output $MAIN_OUTPUT" >/dev/null || true

    local pid=""
    if [[ -f "$PID_FILE" ]]; then
        pid=$(<"$PID_FILE")
        kill -0 "$pid" 2>/dev/null || pid=""
    fi
    if [[ -z "$pid" ]]; then
        # Localhost-only listener: the Android app reaches it through adb reverse.
        wayvnc -o "$output" -g -r -f 30 --log-level=info 127.0.0.1 "$PORT" \
            </dev/null >"$CACHE_DIR/wayvnc.log" 2>&1 &
        pid=$!
        printf '%s\n' "$pid" > "$PID_FILE"
        sleep 1
        kill -0 "$pid" 2>/dev/null || {
            rm -f "$PID_FILE"
            die "WayVNC no arrancó. Consulta $CACHE_DIR/wayvnc.log"
        }
    fi

    if command -v adb >/dev/null 2>&1; then
        adb start-server >/dev/null 2>&1 || true
        local serial
        serial=$(adb_device)
        if [[ -n "$serial" ]]; then
            adb -s "$serial" reverse "tcp:$PORT" "tcp:$PORT" || printf 'AVISO: no se pudo crear adb reverse.\n' >&2
            printf 'ADB conectado (%s); túnel esperado: 127.0.0.1:%s en AVNC.\n' "$serial" "$PORT"
        else
            printf 'AVISO: ADB no ve la tablet. Conecta el cable, activa Depuración USB y acepta la autorización.\n' >&2
        fi
    else
        printf 'AVISO: adb no está instalado; WayVNC está listo, pero falta el transporte USB.\n' >&2
    fi

    printf 'Listo: salida %s (%sx%s), workspace %s, WayVNC en 127.0.0.1:%s.\n' "$output" "$WIDTH" "$HEIGHT" "$target_ws" "$PORT"
    printf 'En AVNC crea una conexión VNC a 127.0.0.1, puerto %s.\n' "$PORT"
}

cmd_status() {
    need swaymsg
    need jq
    local output=""
    [[ -f "$OUTPUT_FILE" ]] && output=$(<"$OUTPUT_FILE")
    if [[ -n "$output" ]] && output_exists "$output"; then
        printf 'Salida Sway: ACTIVA (%s)\n' "$output"
    else
        printf 'Salida Sway: INACTIVA\n'
    fi
    if [[ -f "$PID_FILE" ]] && kill -0 "$(<"$PID_FILE")" 2>/dev/null; then
        printf 'WayVNC: ACTIVO (127.0.0.1:%s)\n' "$PORT"
    else
        printf 'WayVNC: INACTIVO\n'
    fi
    if command -v adb >/dev/null 2>&1; then
        local serial
        serial=$(adb_device)
        if [[ -n "$serial" ]]; then
            printf 'ADB USB: CONECTADO (%s)\n' "$serial"
            adb -s "$serial" reverse --list 2>/dev/null | grep -F "tcp:$PORT" || true
        else
            printf 'ADB USB: NO AUTORIZADO / NO CONECTADO\n'
        fi
    else
        printf 'ADB USB: adb no instalado\n'
    fi
}

cmd_stop() {
    need swaymsg
    need jq
    local output=""
    [[ -f "$OUTPUT_FILE" ]] && output=$(<"$OUTPUT_FILE")

    if [[ -f "$PID_FILE" ]]; then
        local pid
        pid=$(<"$PID_FILE")
        if kill -0 "$pid" 2>/dev/null; then kill "$pid" 2>/dev/null || true; fi
        rm -f "$PID_FILE"
    fi

    if command -v adb >/dev/null 2>&1; then
        local serial
        serial=$(adb_device)
        if [[ -n "$serial" ]]; then adb -s "$serial" reverse --remove "tcp:$PORT" >/dev/null 2>&1 || true; fi
    fi

    if [[ -n "$output" ]] && output_exists "$output"; then
        local workspaces
        workspaces=$(swaymsg -t get_workspaces -r | jq -r --arg output "$output" '.[] | select(.output == $output) | .name')
        while IFS= read -r workspace; do
            [[ -n "$workspace" ]] && swaymsg "workspace $workspace; move workspace to output $MAIN_OUTPUT" >/dev/null || true
        done <<< "$workspaces"
        swaymsg "focus output $MAIN_OUTPUT" >/dev/null || true
        swaymsg "destroy_output $output" >/dev/null || die "No pude destruir $output; muévete los workspaces manualmente si quedaron allí."
    fi
    rm -f "$OUTPUT_FILE"
    printf 'Pantalla-tablet detenida.\n'
}

case "${1:-}" in
    start) shift; [[ $# -le 1 ]] || die "Uso: pantalla-tablet start [N]"; cmd_start "${1:-}" ;;
    status) cmd_status ;;
    stop) cmd_stop ;;
    *) die "Uso: pantalla-tablet {start [N]|status|stop}" ;;
esac
