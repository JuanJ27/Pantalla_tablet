# Pantalla_Tablet para Sway + AVNC

Utilidad de usuario para Fedora/Sway que crea una salida virtual headless, captura esa salida con WayVNC y la muestra en Android mediante AVNC. El transporte previsto es cable USB-C con `adb reverse`; no cambia el compositor ni escribe en la configuración de Sway. La tablet conserva su configuración, salvo que Android requiere habilitar Depuración USB y autorizar este PC para ADB.

## Requisitos

- Sway 1.11 o compatible, ejecutando la sesión gráfica Wayland.
- `swaymsg`, `jq` y `wayvnc` en el PC.
- `adb` (paquete Fedora `android-tools`) para el cable USB.
- Galaxy Tab S10 Lite conectada con cable de datos USB-C a USB-C y AVNC instalada.

Instalación de dependencias (requiere confirmación del usuario y contraseña de administrador):

```bash
sudo dnf install android-tools jq wayvnc
```

## Primera conexión USB

1. En la tablet abre **Ajustes → Acerca de la tablet → Información de software** y toca **Número de compilación** siete veces para habilitar Opciones de desarrollador.
2. Abre **Ajustes → Opciones de desarrollador**, activa **Depuración USB** y acepta el aviso.
3. Conecta la tablet al PC con el cable USB-C a USB-C. En la ventana de autorización de Android acepta la huella RSA del PC; si es tu equipo personal, puedes marcar «Permitir siempre desde este ordenador».
4. Confirma desde el PC:

   ```bash
   adb devices
   ```

   Debe aparecer una serie terminada en `device`, no `unauthorized`. Si solo aparece almacenamiento MTP, revisa el aviso de Depuración USB y vuelve a conectar el cable.

## Uso

Desde la raíz de este repositorio:

```bash
./scripts/pantalla-tablet.sh start
```

Para ejecutarlo desde cualquier directorio, crea un enlace en tu `~/.local/bin` (inclúyelo en `PATH` si todavía no lo está):

```bash
mkdir -p ~/.local/bin
ln -s "$(pwd)/scripts/pantalla-tablet.sh" ~/.local/bin/pantalla-tablet
```

Opcionalmente, añade atajos a `~/.config/sway/config`:

- **Super + Shift + P**: iniciar en el workspace activo.
- **Super + Shift + O**: detener y restaurar los workspaces.

```sway
bindsym $mod+Shift+p exec pantalla-tablet start
bindsym $mod+Shift+o exec pantalla-tablet stop
```

Recarga la configuración con `swaymsg reload` para activar los atajos. Comprueba primero que esas combinaciones no estén asignadas a otra acción en tu configuración.

El comando usa el workspace que estaba enfocado en Sway. Para enviar un workspace específico:

```bash
./scripts/pantalla-tablet.sh start 5
```

En AVNC crea una conexión VNC con:

- **Dirección:** `127.0.0.1`
- **Puerto:** `5910`
- **Seguridad/autenticación:** ninguna (solo si AVNC la solicita; el listener está limitado al PC y se alcanza por el túnel USB).

La salida virtual `HEADLESS-*` se configura a 1920×1200 (relación 16:10) y se coloca a la derecha de la pantalla principal. El workspace elegido se mueve a esa salida; el foco vuelve a la pantalla del PC. Desde ahí, selecciona ese workspace en Sway para trabajar con sus ventanas; AVNC debe estar conectado para verlas.

Comprobar estado y detener:

```bash
./scripts/pantalla-tablet.sh status
./scripts/pantalla-tablet.sh stop
```

`stop` cierra WayVNC, quita el túnel ADB y mueve los workspaces de vuelta a `eDP-1` antes de destruir la salida virtual. No detiene Sway ni cambia archivos de configuración del PC.

## Diagnóstico

- **«adb no está instalado»**: instala `android-tools` con el comando de requisitos.
- **ADB no autorizado**: desbloquea la tablet, activa Depuración USB y acepta el diálogo RSA.
- **AVNC no conecta**: ejecuta `status`; confirma el túnel activo y usa `127.0.0.1:5910` en AVNC mientras el cable siga conectado.
- **WayVNC no inicia**: revisa `~/.cache/pantalla-tablet/wayvnc.log`.
- **No se crea HEADLESS**: verifica que la sesión activa sea Sway y que `swaymsg -t get_outputs` responda.

Puerto por defecto: `5910`. Puede cambiarse para esta invocación mediante, por ejemplo, `PANTALLA_TABLET_PORT=5911 ./scripts/pantalla-tablet.sh start`.

## Límites y seguridad

- USB-C proporciona conexión física, pero el modo MTP por sí solo no ofrece el túnel TCP; `adb reverse` necesita Depuración USB autorizada.
- WayVNC escucha en `127.0.0.1`, no en la red Wi-Fi. El flujo descrito es exclusivamente local a través de ADB reverse.
- La imagen enviada es 1920×1200; puede ajustarse sin tocar Sway con `PANTALLA_TABLET_WIDTH` y `PANTALLA_TABLET_HEIGHT`.
- El comando `stop` es necesario antes de cerrar sesión para limpiar la salida virtual y el workspace.
