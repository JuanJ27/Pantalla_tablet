# Pantalla_Tablet

Utilidad de usuario para convertir una tablet Android (**Samsung Galaxy Tab S9 FE**) en un segundo monitor extendido de alta definición bajo **Hyprland (Wayland)**, utilizando un monitor virtual headless dinámico, **WayVNC**, túnel **ADB por USB**, servicio de supervisión (Watchdog) y respaldo de red por **Tailscale**.

---

## 1. Arquitectura del Sistema

```text
Laptop HP Pavilion (Fedora 43 / Hyprland 0.56.2)
        │
        ├── eDP-1 (Pantalla principal: AU Optronics 1920x1080@60)
        │
        └── TABLET (Output virtual headless dinámico: 1920x1080@60, x=1920)
              ├── WayVNC (0.0.0.0:5910 con -g -r)
              └── Watchdog (Supervisión asíncrona de proceso)
                    │
                    ├── ADB Reverse (USB: tcp:5910 <-> tcp:5910)
                    │
                    └── Tailscale (Red: 100.65.222.39:5910)
                          │
                          ↓
                   Galaxy Tab S9 FE (Android 16)
                        AVNC / RealVNC (:5910)
```

### Parámetros del Monitor Virtual `TABLET`
* **Nombre de Output:** `TABLET` (Salida virtual creada dinámicamente mediante `hyprctl output create headless TABLET`).
* **Resolución:** `1920x1080`
* **Tasa de Refresco:** `60 Hz`
* **Posición:** `x=1920, y=0` (Extensión horizontal a la derecha de `eDP-1`).
* **Escala:** `1`
* **Puerto WayVNC:** `5910`

---

## 2. Configuración de Puertos y Aislamiento Estricto

### Puerto Predeterminado
El puerto predeterminado del proyecto es **`5910`**. El script principal define dinámicamente:

```bash
PORT="${PANTALLA_TABLET_PORT:-5910}"
```

### Conflicto Histórico con QEMU/KVM (`5900`)
En el sistema existe una máquina virtual QEMU/KVM en ejecución (`windows-physical`) cuyo servidor de pantalla SPICE/VNC está reservado en:

```text
127.0.0.1:5900
```

Por esta razón, **el puerto `5900` NO debe utilizarse bajo ninguna circunstancia por Pantalla_Tablet**.

#### Esquema de Aislamiento de Puertos
* **QEMU / VM Windows (`windows-physical`):** `127.0.0.1:5900` (Intacto, reservado para libvirt/SPICE).
* **Pantalla_Tablet / WayVNC:** `0.0.0.0:5910` (Puerto estándar dedicado).

> **REGLA ABSOLUTA:** Pantalla_Tablet no modifica virt-manager, QEMU, libvirt, ni la configuración USB o de SPICE de la máquina virtual `windows-physical`.

---

## 3. Uso Normal y Selección de Workspace

El script ejecutable se encuentra en `scripts/pantalla-tablet.sh` y está enlazado simbólicamente en `~/.local/bin/pantalla-tablet`.

### Comandos de Control

* **Iniciar el servicio (autodetectando workspace activo de `eDP-1` o especificando `N` explícito):**
  ```bash
  pantalla-tablet start [N]
  ```
  *Crea el monitor virtual `TABLET` en Hyprland, le asigna el workspace `N` (o el workspace activo actual de `eDP-1` si no se especifica `N`), preserva el foco en `eDP-1`, aplica la geometría `1920x1080@60, x=1920`, inicia `wayvnc` en `0.0.0.0:5910` (con banderas `-g -r`), arranca el watchdog de supervisión asíncrona, establece el túnel `adb reverse tcp:5910 tcp:5910` y verifica la respuesta RFB.*

  * **Workspace existente con ventanas:** Se traslada completo a `TABLET` conservando sus ventanas.
  * **Workspace inexistente:** Se crea directamente en `TABLET`.
  * **Foco final:** Garantizado en `eDP-1`.

* **Consultar estado:**
  ```bash
  pantalla-tablet status
  ```
  *Muestra el estado en tiempo real del monitor `TABLET`, proceso WayVNC, Watchdog de supervisión, conexión ADB USB, regla ADB reverse y conectividad Tailscale.*

* **Detener el servicio:**
  ```bash
  pantalla-tablet stop
  ```
  *Crea la bandera de detención intencional (`stopping.flag`), detiene el proceso watchdog, remueve la regla `adb reverse`, termina de forma limpia el proceso `wayvnc` y elimina el monitor virtual `TABLET` de Hyprland (restringiendo el cursor exclusivamente a `eDP-1` y restaurando automáticamente los workspaces).*

---

## 4. Servicio de Supervisión Asíncrona (Watchdog)

Para evitar el problema de los "monitores fantasma" y workspaces atrapados en `TABLET` en caso de que WayVNC muera inesperadamente (crash o error fatal de captura), la arquitectura cuenta con un daemon **Watchdog**:

```text
WayVNC (PID X)
    │ (Monitoreo asíncrono cada 1.5s)
    ▼
Watchdog (cmd_watchdog)
    ├── ¿WayVNC sigue vivo? ──> Continuar loop
    └── ¿WayVNC murió?
          ├── ¿Existe stopping.flag? (stop intencional) ──> Salir silenciosamente
          └── ¿NO existe stopping.flag? (crash inesperado)
                ├── Remover ADB reverse (tcp:5910)
                ├── Remover monitor TABLET de Hyprland
                └── Hyprland devuelve los workspaces a eDP-1 automáticamente
```

### Protección contra Carreras y PID Stale
1. **Previene carreras con `stop`:** `pantalla-tablet stop` crea `$STOPPING_FLAG` antes de matar WayVNC. El watchdog detecta la bandera y no ejecuta limpiezas duplicadas ni carreras.
2. **Protección contra PID Stale:** El watchdog verifica explícitamente la cmdline del PID en `/proc/$PID/cmdline` asegurando que corresponda al servidor `wayvnc -o TABLET` de Pantalla_Tablet.

---

## 5. Análisis Técnico de WayVNC y Manejo de Cursores (`24x24`)

### Causa Raíz del Crash `Buffer dimensions: 24x24`
En WayVNC 0.9.1 sobre Hyprland 0.56.2 / Aquamarine 0.15.1, la ausencia de la bandera `-r` (`--render-cursor`) hace que WayVNC inicie una sub-sesión de captura de cursor independiente (`ext_image_copy_capture_cursor_session_v1`). Al mover el mouse sobre la superficie del monitor, el compositor envía fotogramas con las dimensiones del sprite del cursor (`24x24`). WayVNC intenta reconfigurar su pool de buffers GPU principal a `24x24` (`buffer_pool_reconfigure`), lo que falla en el allocador DMABUF (`Failed!`) y provoca un error fatal (`Fatal error while capturing. Exiting...`).

### Solución Adoptada (`-g -r`)
Al ejecutar WayVNC con **`-g -r`** (`wayvnc -o TABLET -g -r -f 60 ...`):
* La opción `-r` (`--render-cursor`) activa la opción `paint_cursors = 1` en el protocolo `ext_image_copy_capture-v1`.
* Hyprland/Aquamarine compone/dibuja el cursor directamente dentro del framebuffer de pantalla completa de `1920x1080`.
* WayVNC **no crea sub-sesiones de cursor ni recibe eventos `24x24`**, garantizando la estabilidad continua del flujo de video durante el movimiento del mouse y touchpad.

---

## 6. Proyectos Externos y Servicios Relacionados

### 1. `Universal Control` (Proyecto Separado y Desactivado)
* **Ubicación:** `/home/jose/ArchivoPortable/03_Desarrollo/Proyectos/Personal/universal-control/`
* **Unidad systemd:** `/home/jose/.config/systemd/user/universal-control.service` (`inactive`/`disabled`).
* **Regla:** Permanecer deshabilitado para evitar conflictos en la interfaz USB AOA (`Failed to claim AOA interface`). No borrar ni modificar.

### 2. QEMU / `windows-physical`
* **Puerto ocupado:** `127.0.0.1:5900` (SPICE/VNC).
* **Regla:** Inviolable. No modificar su configuración ni intentar usar el puerto 5900.

---

## 7. Batería de Pruebas y Validación Final

| Test | Descripción | Resultado |
| :--- | :--- | :--- |
| **TEST 1: Estado Limpio** | Verificación de 0 monitores TABLET, 0 listeners 5910 y 0 reglas ADB al iniciar | **PASS** |
| **TEST 2: start sin argumento** | Autodetecta workspace activo de `eDP-1`, crea `TABLET`, inicia WayVNC + Watchdog, devuelve foco a `eDP-1` | **PASS** |
| **TEST 3: Movimiento de Cursor** | Movimiento de mouse/touchpad continuo. Cero eventos `24x24`, cero crashes en `wayvnc.log` | **PASS** |
| **TEST 4: stop Normal** | `stopping.flag` previene carreras, detiene watchdog, quita ADB reverse, elimina `TABLET`, restaura foco a `eDP-1` | **PASS** |
| **TEST 5: start N existente** | Traslada workspace existente (con ventanas) a `TABLET`, mantiene ventanas intactas, devuelve foco a `eDP-1` | **PASS** |
| **TEST 6: start N inexistente** | Crea nuevo workspace en `TABLET`, devuelve foco a `eDP-1` | **PASS** |
| **TEST 7: Crash WayVNC (Watchdog)** | `kill -9` en WayVNC. Watchdog detecta muerte inesperada en 1.5s, quita ADB reverse y elimina `TABLET` | **PASS** |
| **TEST 8: Recuperación Post-Crash** | `pantalla-tablet start` recupera el servicio completo desde cero sin residuos | **PASS** |
| **TEST 9: Ciclos Repetidos** | 3 ciclos consecutivos `start → stop → start → stop`. Cero PIDs huérfanos, cero listeners duplicados | **PASS** |
| **TEST 10: Puerto 5900 Intacto** | `127.0.0.1:5900` permanece reservado e intacto para `qemu-system-x86_64` (`windows-physical`) | **PASS** |

---

## 8. Registro de Copias de Seguridad (Backups)

Copias de seguridad creadas y verificadas mediante hash SHA-256:

* **Script ejecutable:** [pantalla-tablet.sh](file:///home/jose/ArchivoPortable/03_Desarrollo/Proyectos/Pantalla_Tablet/scripts/pantalla-tablet.sh)
  * Backup: `/home/jose/ArchivoPortable/03_Desarrollo/Proyectos/Pantalla_Tablet/scripts/pantalla-tablet.sh.bak.20260920_135145`
  * **SHA-256:** `4fb1199ee4c26da12bf6f524393461e8001ef6955f0a17ab0e656e9c70b4a8be`
* **Documentación:** [README.md](file:///home/jose/ArchivoPortable/03_Desarrollo/Proyectos/Pantalla_Tablet/README.md)
  * Backup: `/home/jose/ArchivoPortable/03_Desarrollo/Proyectos/Pantalla_Tablet/README.md.bak.20260920_135145`
  * **SHA-256:** `8471cc7012c1a6f396fd59efb17185dd4da2590d86312210a83f105b59f3bdf8`
