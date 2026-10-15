#!/bin/bash
OUTPUT="/home/jose/ArchivoPortable/03_Desarrollo/Proyectos/Pantalla_Tablet/diagnostico/info_sistema.txt"
echo "=== Fedora Version ===" > "$OUTPUT"
cat /etc/os-release | grep PRETTY_NAME >> "$OUTPUT"
echo "=== Kernel ===" >> "$OUTPUT"
uname -r >> "$OUTPUT"
echo "=== KDE Plasma ===" >> "$OUTPUT"
plasmashell --version >> "$OUTPUT" 2>/dev/null || echo "Not found" >> "$OUTPUT"
echo "=== Compositor / Session ===" >> "$OUTPUT"
echo "XDG_SESSION_TYPE: $XDG_SESSION_TYPE" >> "$OUTPUT"
echo "XDG_CURRENT_DESKTOP: $XDG_CURRENT_DESKTOP" >> "$OUTPUT"
echo "WAYLAND_DISPLAY: $WAYLAND_DISPLAY" >> "$OUTPUT"
echo "=== GPU / Driver ===" >> "$OUTPUT"
lspci -nnk | grep -i vga -A 3 >> "$OUTPUT"
echo "=== ADB Devices ===" >> "$OUTPUT"
adb devices >> "$OUTPUT" 2>/dev/null || echo "adb command not found" >> "$OUTPUT"
echo "=== Tablet Info ===" >> "$OUTPUT"
adb shell getprop ro.build.version.release >> "$OUTPUT" 2>/dev/null
adb shell getprop ro.product.model >> "$OUTPUT" 2>/dev/null
adb shell wm size >> "$OUTPUT" 2>/dev/null
adb shell wm config | grep -i orientation >> "$OUTPUT" 2>/dev/null
adb shell getprop ro.product.cpu.abi >> "$OUTPUT" 2>/dev/null
