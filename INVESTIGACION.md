# Investigación: Tablet Android como Segundo Monitor en Linux (USB, Wi-Fi y Tailscale)

## 1. Objetivo
Utilizar una Samsung Galaxy Tab S9 FE como monitor secundario extendido mediante conexión USB, Wi-Fi o Tailscale en un entorno Linux (Fedora 43 + Hyprland), priorizando de forma absoluta la seguridad, reversibilidad, y evitando modificaciones críticas del sistema (como módulos del kernel no probados).

## 2. Diagnóstico del Hardware y Software
Según la auditoría realizada mediante comandos no destructivos (`/diagnostico/info_sistema.txt`):

* **Sistema Operativo**: Fedora Linux 43 (KDE Plasma Desktop Edition)
* **Kernel**: 7.2.4-100.fc43.x86_64
* **Entorno Gráfico**: Hyprland 0.56.2 (Wayland) con motor de scripting Lua 5.4.
* **GPU**: AMD Radeon Vega (Driver `amdgpu`), compatible con aceleración por hardware (`/dev/dri/renderD128`).
* **Tablet**: Samsung SM-X510 (Galaxy Tab S9 FE)
* **Android**: Versión 16 (Arquitectura arm64-v8a)
* **Resolución nativa del panel de la tablet**: 2560x1600 (Relación 16:10)
* **Conexión ADB**: Verificada y autorizada (`R52X90CGTXJ device`).
* **Tailscale PC**: IP `100.65.222.39` (dispositivo `fedora`), interfaz `tailscale0` en zona `trusted` de `firewalld`.
* **Tailscale Tablet**: Dispositivo `tab-s9-fe-de-jose-david` (IP `100.105.161.7`), app `com.tailscale.ipn` instalada.

## 3. Comparativa de Proyectos e Infraestructura Elegida

1. **UScreen**: Evaluado pero descartado por requerir el módulo de kernel `evdi` (DKMS), lo cual vulnera la regla de seguridad y reversibilidad en kernels recientes como el 7.2.4.
2. **Moreland**: Solución nativa en Rust para Wayland. Muy prometedora pero en estado inicial de desarrollo.
3. **Solución Implementada (Hyprland Headless + WayVNC + ADB / Tailscale)**: 100% nativa en espacio de usuario. No requiere root, no altera el kernel y es 100% reversible.

## 4. Configuración Validada y Probada en la Fase 1

* **Creación del Monitor Virtual**: `hyprctl output create headless` -> `HEADLESS-2`.
* **Resolución y Escalado Óptimo**: `2560x1600@60` con `scale: 1.3333334` (emparejamiento 1:1 nativo con el panel físico de la tablet y tamaño de interfaz legible).
* **Servidor VNC**: `wayvnc` con la variable `WLR_NO_HARDWARE_CURSORS=1`, aceleración por hardware GPU (`/dev/dri/renderD128`) y la bandera `-r` (`--render-cursor`). Esto impide que Hyprland falle al solicitar búferes de cursor en outputs virtuales.
* **Navegación por Atajos (En memoria)**:
  * `SUPER + SHIFT + P` $\rightarrow$ Mover la ventana enfocada a la Tablet (`HEADLESS-2`).
  * `SUPER + SHIFT + I` $\rightarrow$ Devolver la ventana enfocada a la Pantalla Principal (`eDP-1`).

## 5. Investigación de Transporte Dual: USB y Tailscale (VPN P2P)

```text
                         ┌── USB → ADB Reverse (127.0.0.1:5900) ──┐
                         │                                        │
HEADLESS-2 → WayVNC :5900 ────────────────────────────────────────┼──→ [Tablet VNC Client]
                         │                                        │
                         └── Tailscale (100.65.222.39:5900) ──────┘
```

### A. Coexistencia Técnica de Sockets
* `wayvnc` abre el socket servidor en la PC (escuchando en `0.0.0.0:5900` o en `100.65.222.39:5900`).
* `adb reverse tcp:5900 tcp:5900` actúa como un cliente local que conecta el tráfico del puerto 5900 de la tablet hacia el `127.0.0.1:5900` de la PC.
* La conexión vía Tailscale viaja de forma directa sobre la VPN cifrada WireGuard desde `100.105.161.7` hacia `100.65.222.39:5900`.
* **No existe ningún conflicto de sockets o puertos**. Ambos métodos alimentan simultáneamente al mismo servidor `wayvnc` y al mismo monitor `HEADLESS-2`.

### B. Análisis de Seguridad y Firewall (`firewalld`)
* **Aislamiento por default**: En Fedora, la interfaz `tailscale0` es asignada automáticamente a la zona **`trusted`** de `firewalld`.
* **Cero cambios en Firewall**: El puerto 5900 transmitido por `tailscale0` está permitido nativamente entre los nodos del tailnet, mientras que la interfaz Wi-Fi pública/local (`wlo1`) en la zona `FedoraWorkstation` se mantiene cerrada y protegida de otros dispositivos de la red.
* **Escucha Restringida (Opción C)**: Si `wayvnc` se configura para hacer *bind* específicamente en la IP de Tailscale (`100.65.222.39`), ni siquiera la red local Wi-Fi podrá enviar paquetes al puerto VNC aunque se abra el puerto en el firewall.

### C. Comparativa de Rendimiento

| Parámetro | USB (ADB Reverse) | Tailscale (Wi-Fi P2P) |
|---|---|---|
| **Medio** | Cable físico USB | VPN WireGuard sobre Wi-Fi |
| **Latencia esperada** | 2 – 5 ms | 15 – 30 ms (Wi-Fi 5 GHz) |
| **Ancho de banda** | ~480 Mbps | 300 – 866 Mbps |
| **Estabilidad / Jitter** | Nula interferencia | Depende de la calidad de señal Wi-Fi |
| **Carga de CPU (Cifrado)** | Nula | Despreciable (<1% por aceleración AES-NI / ARMv8) |

## 6. Plan de Implementación por Fases (Prueba No Destructiva)

1. **Fase 1 (Prueba de escucha Tailscale)**:
   * Activar la VPN en la app Tailscale de Android.
   * Re-iniciar `wayvnc` en `0.0.0.0:5900` o `100.65.222.39:5900` (manteniendo `WLR_NO_HARDWARE_CURSORS=1`).
   * Mantener el túnel ADB `adb reverse tcp:5900 tcp:5900`.
2. **Fase 2 (Prueba de Conexión en Tablet)**:
   * Crear el perfil "Tailscale" en el cliente VNC (Host: `100.65.222.39`, Puerto: `5900`).
   * Evaluar la fluidez sin cable USB.
3. **Fase 3 (Automatización final)**:
   * Script `pantalla_tablet` de control `start / stop / status`.

## 7. Registro de Cambios y Reversibilidad
Todas las modificaciones persistentes en paquetes se registran en `CHANGELOG.md`. Las configuraciones dinámicas de Hyprland y WayVNC viven en memoria y desaparecen al reiniciar o limpiar la sesión.
