# Diseño local: Fedora + Sway + Galaxy Tab S10 Lite

## Perfil objetivo y validación

- Perfil de destino probado: Fedora 43, Sway 1.11 en Wayland, salida física `eDP-1` de 1366×768 y Samsung Galaxy Tab S10 Lite con AVNC por cable USB-C.
- Sway creó `HEADLESS-1` a 1920×1200; WayVNC informó captura del output y escucha en `127.0.0.1:5910`.
- Se verificó la tablet autorizada por ADB y el uso de `adb reverse`; el registro WayVNC confirma conexión de un cliente VNC.
- No se cambia el compositor ni la red/firewall. El README ofrece configuración opcional del comando global y atajos, fuera del controlador principal.

## Flujo técnico

1. Sway IPC crea una salida headless dinámica `HEADLESS-*`.
2. `swaymsg` la configura a 1920×1200 (16:10) a la derecha de `eDP-1` y mueve a ella el workspace seleccionado.
3. WayVNC captura solamente esa salida y escucha en `127.0.0.1:5910`.
4. `adb reverse tcp:5910 tcp:5910` publica el puerto del PC en el loopback de Android. AVNC se conecta a `127.0.0.1:5910`.
5. Al detener, el script devuelve los workspaces a `eDP-1`, retira la regla ADB y destruye la salida virtual.

El listener queda limitado a loopback; no se abre un puerto VNC a Wi-Fi ni a Tailscale. El puerto 5900 no se usa.

## Preparación

Consultar `README.md` para prerequisitos, comandos `start`, `status` y `stop`, y la configuración opcional de atajos. El controlador no escribe en la configuración de Sway.

## Recuperación y alcance

La confirmación de interacción táctil prolongada y ciclos repetidos de `start`/`stop` requiere probarlos en el equipo objetivo. Si WayVNC termina de forma inesperada, consulta `status`; ejecutar `stop` limpia la salida headless residual y `start` vuelve a levantar el servicio.
