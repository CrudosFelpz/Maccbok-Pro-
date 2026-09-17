#!/bin/bash
# fix-onedrive.sh
#
# Repara el error "OneDrive no puede iniciarse" en macOS con el código:
#   FilterStatus::-3 (0xfffffffd) [Permanent]
#   SyncRootManagerTools.cpp:128 CommonSyncRootRegisterVnop
#
# Ese error significa que la extensión "File Provider" de OneDrive no consigue
# registrar su carpeta de sincronización en macOS. Casi siempre es por una de
# estas causas:
#   1. La extensión está desactivada en Ajustes del Sistema.
#   2. Quedó un dominio de File Provider corrupto de una instalación anterior.
#   3. Hay dos OneDrive instalados (App Store + independiente) y chocan.
#   4. Contenedores/caches de OneDrive corruptos tras actualizar macOS.
#
# Uso:
#   bash fix-onedrive.sh            # diagnóstico + reparación
#   bash fix-onedrive.sh --diagnose # solo diagnóstico, no cambia nada
#
# NO ejecutar con sudo: las rutas dependen de tu usuario.
# Tus archivos en OneDrive no se borran: se resincronizan desde la nube al
# volver a iniciar sesión. Lo único que se pierde es la sesión y la config local.

set -u

DIAGNOSE_ONLY=0
[[ "${1:-}" == "--diagnose" ]] && DIAGNOSE_ONLY=1

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "Este script es solo para macOS." >&2
  exit 1
fi
if [[ "$(id -u)" -eq 0 ]]; then
  echo "No lo ejecutes con sudo. Ejecútalo como tu usuario normal." >&2
  exit 1
fi

BACKUP="$HOME/Desktop/OneDrive-reset-backup-$(date +%Y%m%d-%H%M%S)"
LOG="$BACKUP/fix-onedrive.log"

say()  { printf '\n==> %s\n' "$*"; }
info() { printf '    %s\n' "$*"; }
run()  { if [[ $DIAGNOSE_ONLY -eq 1 ]]; then info "(diagnóstico) $*"; else info "\$ $*"; "$@" 2>&1 | sed 's/^/      /'; fi; }

mkdir -p "$BACKUP"
exec > >(tee -a "$LOG") 2>&1

say "Diagnóstico"
info "macOS: $(sw_vers -productVersion) ($(sw_vers -buildVersion))"
info "Usuario: $USER"
info "Log: $LOG"

# --- 1. Instalaciones de OneDrive -------------------------------------------
say "Instalaciones de OneDrive encontradas"
FOUND=0
for app in /Applications/OneDrive.app "$HOME/Applications/OneDrive.app"; do
  if [[ -d "$app" ]]; then
    FOUND=$((FOUND+1))
    ver=$(defaults read "$app/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null || echo "?")
    if [[ -d "$app/Contents/_MASReceipt" ]]; then kind="App Store"; else kind="Independiente (descarga de Microsoft)"; fi
    info "$app  versión $ver  [$kind]"
  fi
done
if [[ $FOUND -eq 0 ]]; then
  info "No hay OneDrive.app instalado. Descárgalo de https://go.microsoft.com/fwlink/?linkid=823060 e instálalo antes de seguir."
  exit 1
fi
if [[ $FOUND -gt 1 ]]; then
  info "AVISO: hay más de una copia de OneDrive. Deja solo una (recomendado: la de /Applications) y vuelve a ejecutar."
fi

# --- 2. Estado de la extensión File Provider --------------------------------
say "Extensiones File Provider registradas en macOS (+ activa, - desactivada, ! conflicto)"
pluginkit -m -p com.apple.fileprovider-nonui 2>/dev/null | sed 's/^/    /' || info "pluginkit no disponible"
ONEDRIVE_EXT_IDS=$(pluginkit -m -p com.apple.fileprovider-nonui 2>/dev/null | awk '{print $2}' | grep -i onedrive || true)

say "Dominios File Provider actuales"
fileproviderctl domain list 2>/dev/null | sed 's/^/    /' || info "fileproviderctl no disponible (macOS < 12.1)"

say "Carpetas de sincronización en ~/Library/CloudStorage"
ls -d "$HOME/Library/CloudStorage"/OneDrive* 2>/dev/null | sed 's/^/    /' || info "(ninguna)"

say "¿Mac gestionado por MDM? (un perfil corporativo puede bloquear File Provider)"
profiles status -type enrollment 2>/dev/null | sed 's/^/    /' || info "no se pudo consultar"

if [[ $DIAGNOSE_ONLY -eq 1 ]]; then
  say "Fin del diagnóstico. Ejecuta sin --diagnose para reparar."
  exit 0
fi

# --- 3. Cerrar OneDrive -------------------------------------------------------
say "Cerrando OneDrive y su extensión"
osascript -e 'tell application "OneDrive" to quit' >/dev/null 2>&1 || true
sleep 2
pkill -x OneDrive 2>/dev/null || true
pkill -f "OneDrive File Provider" 2>/dev/null || true
pkill -f "OneDrive Finder Integration" 2>/dev/null || true
sleep 1

# --- 4. Eliminar dominios File Provider de OneDrive ---------------------------
say "Eliminando dominios File Provider de OneDrive (se recrean al iniciar sesión)"
fileproviderctl domain list 2>/dev/null | grep -i onedrive | awk '{print $1}' | while read -r dom; do
  [[ -z "$dom" ]] && continue
  run fileproviderctl domain remove "$dom"
done

# --- 5. Ejecutar el reset oficial de Microsoft (si existe) ---------------------
say "Ejecutando el script de reset oficial de Microsoft"
RESET_DONE=0
for app in /Applications/OneDrive.app "$HOME/Applications/OneDrive.app"; do
  for r in ResetOneDriveAppStandalone.command ResetOneDriveApp.command; do
    if [[ -x "$app/Contents/Resources/$r" ]]; then
      run bash "$app/Contents/Resources/$r"
      RESET_DONE=1
      break 2
    fi
  done
done
[[ $RESET_DONE -eq 0 ]] && info "No se encontró el reset oficial; se hará limpieza manual."

# --- 6. Limpieza manual de contenedores y caches (se mueven, no se borran) -------
say "Moviendo contenedores y caches de OneDrive a $BACKUP"
PATHS=(
  "$HOME/Library/Containers/com.microsoft.OneDrive-mac"
  "$HOME/Library/Containers/com.microsoft.OneDrive.FileProvider"
  "$HOME/Library/Containers/com.microsoft.OneDrive-mac.FileProvider"
  "$HOME/Library/Containers/com.microsoft.OneDriveLauncher"
  "$HOME/Library/Containers/com.microsoft.OneDrive.FinderSync"
  "$HOME/Library/Group Containers/UBF8T346G9.OneDriveStandaloneSuite"
  "$HOME/Library/Group Containers/UBF8T346G9.OneDriveSyncClientSuite"
  "$HOME/Library/Group Containers/UBF8T346G9.OfficeOneDriveSyncIntegration"
  "$HOME/Library/Application Support/OneDrive"
  "$HOME/Library/Application Support/com.microsoft.OneDrive"
  "$HOME/Library/Application Support/OneDriveUpdater"
  "$HOME/Library/Caches/OneDrive"
  "$HOME/Library/Caches/com.microsoft.OneDrive"
  "$HOME/Library/Caches/com.microsoft.OneDriveUpdater"
  "$HOME/Library/Preferences/com.microsoft.OneDrive.plist"
  "$HOME/Library/Preferences/com.microsoft.OneDriveUpdater.plist"
  "$HOME/Library/Preferences/com.microsoft.OneDriveStandaloneUpdater.plist"
  "$HOME/Library/Logs/OneDrive"
)
for p in "${PATHS[@]}"; do
  if [[ -e "$p" ]]; then
    dest="$BACKUP/$(echo "${p#$HOME/Library/}" | tr '/' '_')"
    info "mover: $p"
    mv "$p" "$dest" 2>/dev/null || info "  (no se pudo mover, protegido por el sistema; se ignora)"
  fi
done

# --- 7. Credenciales cacheadas en el Llavero ----------------------------------
say "Borrando credenciales cacheadas de OneDrive en el Llavero (tendrás que iniciar sesión de nuevo)"
for label in "OneDrive Cached Credential" "OneDrive Standalone Cached Credential" "OneDrive Cached Credential Business"; do
  while security delete-generic-password -l "$label" >/dev/null 2>&1; do :; done
done

# --- 8. Reactivar la extensión File Provider ----------------------------------
say "Reactivando la extensión File Provider de OneDrive"
if [[ -n "$ONEDRIVE_EXT_IDS" ]]; then
  for id in $ONEDRIVE_EXT_IDS; do
    run pluginkit -e use -i "$id"
  done
else
  for id in com.microsoft.OneDrive.FileProvider com.microsoft.OneDrive-mac.FileProvider; do
    pluginkit -e use -i "$id" 2>/dev/null || true
  done
fi
info "Estado tras reactivar:"
pluginkit -m -p com.apple.fileprovider-nonui 2>/dev/null | grep -i onedrive | sed 's/^/    /' || info "    (OneDrive aún no aparece; aparecerá tras el reinicio)"

# --- 9. Siguiente paso: reinicio obligatorio ----------------------------------
say "LISTO. Ahora haz esto en orden:"
info "1. REINICIA el Mac (obligatorio: el registro del sync root solo se limpia al reiniciar)."
info "2. Abre Ajustes del Sistema > General > Ítems de inicio y extensiones > Proveedores de archivos"
info "   y comprueba que OneDrive está ACTIVADO."
info "3. Abre OneDrive e inicia sesión. Los archivos se resincronizan desde la nube."
info "4. Si el error persiste tras esto, desinstala OneDrive (arrástralo a la Papelera),"
info "   vuelve a ejecutar este script, instala la última versión desde"
info "   https://go.microsoft.com/fwlink/?linkid=823060 y reinicia otra vez."
info ""
info "Copia de seguridad de lo eliminado: $BACKUP"
