#!/bin/bash
# Muestra la memoria y la CPU que usan Carpetas Dock y cada una de tus carpetas.
PIDS=$(pgrep -x CarpetasDock)
if [ -z "$PIDS" ]; then echo "Carpetas Dock no se está ejecutando."; exit 0; fi
printf "%-24s %8s %7s %12s\n" "Carpeta" "PID" "CPU" "Memoria"
for P in $PIDS; do
  NAME=$(ps -o command= -p "$P" | sed -E 's#.*/([^/]+)\.app/Contents/MacOS/.*#\1#')
  CPU=$(ps -o %cpu= -p "$P" | tr -d ' ')
  FP=$(footprint -p "$P" 2>/dev/null | grep -m1 -i "footprint:" | sed -E 's/.*[Ff]ootprint: *([0-9.]+ [KMG]B).*/\1/')
  printf "%-24s %8s %6s%% %12s\n" "$NAME" "$P" "$CPU" "${FP:-?}"
done
