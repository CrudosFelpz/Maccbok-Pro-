#!/bin/bash
# clean-mac.sh
#
# Limpieza segura de macOS. Por defecto SIMULA: muestra cuánto liberaría cada
# elemento sin borrar nada. Para borrar de verdad, añade --apply.
#
# Qué limpia SIEMPRE (todo se regenera solo, riesgo nulo):
#   cachés de usuario, logs de usuario, DerivedData de Xcode, simuladores
#   no disponibles, cachés de Homebrew / npm / yarn / pnpm / pip.
#
# Qué limpia SOLO si lo pides (decisión tuya):
#   --trash       vaciar la Papelera (irreversible)
#   --docker      docker system prune (contenedores parados, imágenes sin uso,
#                 caché de build; NO toca volúmenes)
#   --snapshots   adelgazar instantáneas locales de Time Machine (pide sudo)
#
# Qué NO toca nunca (revísalo tú con disk-report.sh):
#   copias de seguridad del iPhone, fototeca, Descargas, Mail, Mensajes,
#   documentos, aplicaciones.
#
# Uso:
#   bash clean-mac.sh                          # simulación
#   bash clean-mac.sh --apply                  # limpieza segura
#   bash clean-mac.sh --apply --trash --docker --snapshots
#
# Consejo: cierra el navegador y tus apps antes de usar --apply.

set -u
if [[ "$(uname -s)" != "Darwin" ]]; then echo "Solo macOS." >&2; exit 1; fi
if [[ "$(id -u)" -eq 0 ]]; then echo "No lo ejecutes con sudo." >&2; exit 1; fi

APPLY=0; TRASH=0; DOCKER=0; SNAPS=0
for a in "$@"; do
  case "$a" in
    --apply) APPLY=1 ;;
    --trash) TRASH=1 ;;
    --docker) DOCKER=1 ;;
    --snapshots) SNAPS=1 ;;
    *) echo "Opción desconocida: $a" >&2; exit 1 ;;
  esac
done

LOG="$HOME/Desktop/clean-mac-$(date +%Y%m%d-%H%M%S).log"
exec > >(tee "$LOG") 2>&1

TOTAL_KB=0
free_now() { df -h / | tail -1 | awk '{print $4}'; }
hum() { awk -v k="$1" 'BEGIN{ s="KMGT"; i=1; v=k; while (v>=1024 && i<4){v/=1024; i++} printf("%6.1f %s", v, substr(s,i,1)) }'; }

if [[ $APPLY -eq 1 ]]; then
  echo "MODO REAL. Libre antes: $(free_now)"
else
  echo "SIMULACIÓN (no se borra nada). Libre ahora: $(free_now)"
fi
echo "Log: $LOG"
echo

# Vacía el CONTENIDO de un directorio (no el directorio). Solo dentro de $HOME.
# $1 = etiqueta, $2 = ruta, $3 = patrón de nombres a excluir (opcional)
clean_dir() {
  local label="$1" dir="$2" excl="${3:-}"
  [[ -d "$dir" ]] || return 0
  case "$dir" in "$HOME"/?*) ;; *) echo "  [saltado, fuera de HOME] $dir"; return 0 ;; esac
  local kb; kb=$(du -skx "$dir" 2>/dev/null | cut -f1); kb=${kb:-0}
  [[ "$kb" -lt 1024 ]] && return 0
  printf '  %s  %s\n' "$(hum "$kb")" "$label"
  TOTAL_KB=$((TOTAL_KB + kb))
  if [[ $APPLY -eq 1 ]]; then
    if [[ -n "$excl" ]]; then
      find "$dir" -mindepth 1 -maxdepth 1 ! -name "$excl" -exec rm -rf {} + 2>/dev/null
    else
      find "$dir" -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null
    fi
  fi
}

# Ejecuta un comando de limpieza si la herramienta existe.
# $1 = etiqueta, $2 = herramienta, resto = comando
run_tool() {
  local label="$1" tool="$2"; shift 2
  command -v "$tool" >/dev/null 2>&1 || return 0
  printf '  %s\n' "$label"
  if [[ $APPLY -eq 1 ]]; then "$@" 2>&1 | sed 's/^/      /'; fi
}

echo "== Limpieza segura (siempre) =="
clean_dir "Cachés de usuario (excepto las de Apple)" "$HOME/Library/Caches" "com.apple.*"
clean_dir "Logs de usuario"                          "$HOME/Library/Logs"
clean_dir "Xcode DerivedData"                        "$HOME/Library/Developer/Xcode/DerivedData"
clean_dir "Xcode iOS DeviceSupport (se vuelve a descargar)" "$HOME/Library/Developer/Xcode/iOS DeviceSupport"
clean_dir "Caché de npm"                             "$HOME/.npm/_cacache"
clean_dir "Caché de yarn"                            "$HOME/Library/Caches/Yarn"
clean_dir "Caché de pip"                             "$HOME/Library/Caches/pip"
clean_dir "Caché de Gradle"                          "$HOME/.gradle/caches"
clean_dir "Caché de CocoaPods"                       "$HOME/Library/Caches/CocoaPods"

run_tool "Simuladores de iOS no disponibles"  xcrun   xcrun simctl delete unavailable
run_tool "Homebrew: versiones antiguas y caché" brew   brew cleanup -s --prune=all
run_tool "pnpm: paquetes huérfanos"            pnpm   pnpm store prune

echo
echo "== Opcionales (solo con su flag) =="
if [[ $TRASH -eq 1 ]]; then
  clean_dir "Papelera" "$HOME/.Trash"
else
  kb=$(du -skx "$HOME/.Trash" 2>/dev/null | cut -f1); kb=${kb:-0}
  [[ "$kb" -ge 1024 ]] && printf '  %s  Papelera  (usa --trash para vaciarla; es irreversible)\n' "$(hum "$kb")"
fi

if command -v docker >/dev/null 2>&1; then
  if [[ $DOCKER -eq 1 ]]; then
    run_tool "Docker: contenedores parados, imágenes sin uso y caché de build (sin volúmenes)" docker docker system prune -af
  else
    printf '  Docker instalado  (usa --docker para limpiar imágenes y caché sin uso; no toca volúmenes)\n'
  fi
fi

SNAP_COUNT=$(tmutil listlocalsnapshots / 2>/dev/null | grep -c "com.apple.TimeMachine")
if [[ "${SNAP_COUNT:-0}" -gt 0 ]]; then
  if [[ $SNAPS -eq 1 ]]; then
    printf '  Instantáneas locales de Time Machine: %s encontradas, adelgazando (pide contraseña)\n' "$SNAP_COUNT"
    [[ $APPLY -eq 1 ]] && sudo tmutil thinlocalsnapshots / 999999999999 4 2>&1 | sed 's/^/      /'
  else
    printf '  Instantáneas locales de Time Machine: %s  (usa --snapshots; suelen ocupar varios GB invisibles)\n' "$SNAP_COUNT"
  fi
fi

echo
echo "== Resultado =="
if [[ $APPLY -eq 1 ]]; then
  echo "  Liberado (carpetas medidas): ~$(hum "$TOTAL_KB" | sed 's/^ *//')  más lo que hayan liberado las herramientas"
  echo "  Libre ahora: $(free_now)"
  echo "  Reinicia el Mac para liberar también el swap."
else
  echo "  Liberaría ~$(hum "$TOTAL_KB" | sed 's/^ *//') solo en carpetas, más lo que liberen las herramientas."
  echo "  Si el resumen te parece bien, ejecuta de nuevo con --apply."
fi
echo
echo "Lo que más pesa suele estar fuera de este script: copias del iPhone, fototeca,"
echo "Descargas y Mail. Mídelos con disk-report.sh y decide tú qué conservar."
