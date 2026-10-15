# Registro de Cambios (Changelog) - Proyecto Pantalla Tablet

Este archivo contiene el historial de modificaciones persistentes o relevantes realizadas en el sistema como parte del proyecto de monitor extendido.

| Fecha/Hora | Comando/Acción | Motivo | Componente Afectado | Estado Anterior | Estado Posterior | Reversión |
| 2026-09-15 19:31 | `sudo dnf install -y wayvnc` | Servidor VNC para Wayland | Sistema Fedora (paquetes wayvnc, neatvnc, aml) | No instalado | Instalado v0.9.1 | `sudo dnf remove -y wayvnc neatvnc aml` |
| 2026-09-15 19:49 | `adb reverse tcp:5900 tcp:5900` | Reconstrucción de túnel tras reconexión USB | Conexión ADB Tablet | Inactivo | Activo (puerto 5900) | `adb reverse --remove tcp:5900` |
| 2026-09-15 20:13 | `adb reverse tcp:5900 tcp:5900` | Re-establecimiento de túnel tras reconexión física de tablet | Conexión ADB Tablet | Inactivo | Activo (puerto 5900) | `adb reverse --remove tcp:5900` |
| 2026-09-15 22:05 | `pantalla-tablet` script y symlink | Creación de utilidad de usuario en `~/.local/bin/pantalla-tablet` | Scripts de usuario | No existente | Creado y funcional (`start`/`stop`/`status`) | `rm ~/.local/bin/pantalla-tablet scripts/pantalla-tablet.sh` |
| 2026-09-15 22:14 | Bindings persistentes en `custom.lua` | Restauración persistente de `SUPER+SHIFT+P` (HEADLESS-2) y `SUPER+SHIFT+I` (eDP-1) | Configuración Hyprland Lua | No persistidos | Activos y cargados en memoria | Eliminar líneas correspondientes en `custom.lua` |
| 2026-09-15 22:41 | Binding `PRINT` en `custom.lua` | Actualización de `PRINT` a `flameshot screen -c` para evadir salto de cursor multi-monitor | Configuración Hyprland Lua | `flameshot gui` | `flameshot screen -c` | Restaurar `flameshot gui` en `custom.lua` |
| 2026-09-16 00:03 | Binding `PRINT` en `custom.lua` | Restauración definitiva de `PRINT` a `flameshot gui` tras eliminar el monitor fantasma `HEADLESS-1` | Configuración Hyprland Lua | `flameshot screen -c` | `flameshot gui` | Cambiar a `flameshot screen -c` |
| 2026-10-15 | Adaptación Sway | Adaptar la utilidad a Sway headless con WayVNC/ADB reverse y documentar integración opcional con AVNC y atajos | `scripts/pantalla-tablet.sh`, `README.md`, `INVESTIGACION.md` | Controlador específico de Hyprland, documentación obsoleta | Controlador para Sway y pasos reproducibles de instalación/uso | Volver al commit anterior de estos archivos |
