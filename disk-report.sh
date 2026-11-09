#!/bin/bash
# disk-report.sh
#
# Informe de uso de disco en macOS. SOLO LEE, no borra nada.
# Genera un informe en el Escritorio para decidir qué liberar de forma
# estratégica (primero lo que no tiene coste: caches, snapshots, basura;
# después lo que requiere decisión: backups de iPhone, fototeca, descargas).
#
# Uso:
#   bash disk-report.sh
#
# Para que pueda medir Mail, Mensajes, Safari y Time Machine necesita que
# Terminal tenga "Acceso total al disco" (Ajustes > Privacidad y seguridad).
# Sin eso, esas carpetas aparecerán como 0 o con "Operation not permitted".

set -u
if [[ "$(uname -s)" != "Darwin" ]]; then echo "Solo macOS." >&2; exit 1; fi

OUT="$HOME/Desktop/disk-report-$(date +%Y%m%d-%H%M%S).txt"
exec > >(tee "$OUT") 2>&1

hr()  { printf '\n=== %s ===\n' "$*"; }
hum() { # KB -> legible
  awk -v k="$1" 'BEGIN{ s="KMGT"; i=1; v=k; while (v>=1024 && i<4){v/=1024; i++} printf("%6.1f %s", v, substr(s,i,1)) }'
}
# Mide una lista de rutas con du y las imprime de mayor a menor.
measure() {
  local p
  for p in "$@"; do
    [[ -e "$p" ]] || continue
    local k
    k=$(du -skx "$p" 2>/dev/null | cut -f1)
    [[ -n "$k" ]] && printf '%s\t%s\n' "$k" "$p"
  done | sort -rn | while IFS=$'\t' read -r k p; do
    printf '  %s  %s\n' "$(hum "$k")" "${p/#$HOME/~}"
  done
}

hr "Equipo"
echo "  $(sysctl -n hw.model)  macOS $(sw_vers -productVersion)  usuario $USER"
echo "  Informe guardado en: $OUT"

hr "Disco (df): tamaño / usado / libre"
df -h / | tail -1 | awk '{printf "  Total %s  Usado %s  Libre %s  (%s)\n",$2,$3,$4,$5}'
diskutil info / 2>/dev/null | grep -E "Container Total Space|Container Free Space|Volume Used Space" | sed 's/^ */  /'

hr "Snapshots locales de Time Machine (ocupan espacio 'purgable' invisible)"
tmutil listlocalsnapshots / 2>/dev/null | sed 's/^/  /' || echo "  (sin acceso o sin snapshots)"
echo "  Si hay varios: sudo tmutil deletelocalsnapshots <fecha>  (o: sudo tmutil thinlocalsnapshots / 999999999999 4)"

hr "Memoria virtual / swap (se libera reiniciando)"
measure /private/var/vm

hr "Carpetas de usuario (nivel 1)"
measure "$HOME"/* "$HOME"/.Trash

hr "Dentro de ~/Library (lo que de verdad suele crecer)"
measure "$HOME"/Library/*

hr "Caches y basura de desarrollo (seguro de borrar)"
measure \
  "$HOME/Library/Caches" \
  "$HOME/Library/Logs" \
  "$HOME/Library/Developer/Xcode/DerivedData" \
  "$HOME/Library/Developer/Xcode/Archives" \
  "$HOME/Library/Developer/Xcode/iOS DeviceSupport" \
  "$HOME/Library/Developer/CoreSimulator" \
  "$HOME/Library/Developer/XCPGDevices" \
  "$HOME/.npm" "$HOME/.yarn" "$HOME/.pnpm-store" "$HOME/.cache" \
  "$HOME/.gradle" "$HOME/.m2" "$HOME/.cocoapods" "$HOME/.cargo/registry" \
  "$HOME/.docker" "$HOME/Library/Containers/com.docker.docker" \
  "$HOME/Library/Caches/Homebrew" "$HOME/Library/Caches/pip" \
  "$HOME/Library/Caches/com.apple.dt.Xcode" \
  "$HOME/Library/Caches/Google" "$HOME/Library/Caches/com.spotify.client" \
  "$HOME/Library/Application Support/Code/Cache" \
  "$HOME/Library/Application Support/Code/CachedData" \
  "$HOME/Library/Application Support/Google/Chrome/Default/Cache" \
  "$HOME/Library/Application Support/Slack/Cache" \
  "$HOME/Library/Application Support/discord/Cache" \
  /Library/Caches /private/var/folders /private/var/log /private/var/tmp

hr "Cosas grandes que requieren decisión (no borrar a ciegas)"
measure \
  "$HOME/Library/Application Support/MobileSync/Backup" \
  "$HOME/Pictures" "$HOME/Movies" "$HOME/Music" "$HOME/Downloads" "$HOME/Desktop" "$HOME/Documents" \
  "$HOME/Library/Mail" "$HOME/Library/Messages" \
  "$HOME/Library/Mobile Documents" "$HOME/Library/CloudStorage" \
  "$HOME/Library/Application Support/Adobe" \
  "$HOME/Library/Application Support/Steam" \
  "$HOME/Library/Application Support/Final Cut Pro" \
  "$HOME/Movies/Final Cut Backups.localized" \
  "$HOME/Library/Application Support/Logic" \
  "$HOME/Library/Audio" \
  "$HOME/Parallels" "$HOME/Virtual Machines.localized" "$HOME/VirtualBox VMs" \
  /Library/Developer /Library/Application\ Support /Users/Shared
ls -d "$HOME"/Pictures/*.photoslibrary 2>/dev/null | while read -r p; do
  printf '  %s  %s  (Fototeca; si usas iCloud: Fotos > Ajustes > Optimizar almacenamiento)\n' "$(hum "$(du -skx "$p" 2>/dev/null | cut -f1)")" "${p/#$HOME/~}"
done

hr "Aplicaciones más pesadas (/Applications)"
du -skx /Applications/*.app 2>/dev/null | sort -rn | head -15 | while IFS=$'\t' read -r k p; do
  printf '  %s  %s\n' "$(hum "$k")" "$p"
done

hr "Carpetas node_modules dentro de tu home (regenerables con npm install)"
find "$HOME" -xdev -type d -name node_modules -prune 2>/dev/null | head -200 | while read -r p; do
  printf '%s\t%s\n' "$(du -skx "$p" 2>/dev/null | cut -f1)" "$p"
done | sort -rn | head -15 | while IFS=$'\t' read -r k p; do
  printf '  %s  %s\n' "$(hum "$k")" "${p/#$HOME/~}"
done

hr "Top 25 directorios más grandes del home (profundidad 3)"
du -kxd 3 "$HOME" 2>/dev/null | sort -rn | head -25 | while IFS=$'\t' read -r k p; do
  printf '  %s  %s\n' "$(hum "$k")" "${p/#$HOME/~}"
done

hr "Top 30 archivos de más de 300 MB"
find "$HOME" /Users/Shared /private/var /Library -xdev -type f -size +300M 2>/dev/null -print0 \
  | xargs -0 du -sk 2>/dev/null | sort -rn | head -30 | while IFS=$'\t' read -r k p; do
  printf '  %s  %s\n' "$(hum "$k")" "${p/#$HOME/~}"
done

hr "Otros volúmenes / contenedores APFS"
diskutil apfs list 2>/dev/null | grep -E "Name:|Capacity (In Use|Consumed)|Capacity Not Allocated" | sed 's/^ */  /'

hr "Fin"
echo "  Pega el contenido de $OUT en el chat para decidir qué liberar."
