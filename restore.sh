#!/bin/bash
# =============================================================================
#  mac-restore.sh — Restauración masiva de Macs Apple Silicon
#  Requiere: Apple Configurator 2 instalado + Macs en modo DFU
# =============================================================================

set -eo pipefail

# ─── Colores ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

# ─── Configuración ────────────────────────────────────────────────────────────
CFGUTIL=""
if command -v cfgutil >/dev/null 2>&1; then
  CFGUTIL=$(command -v cfgutil)
elif [ -x "/Library/Apple/usr/bin/cfgutil" ]; then
  CFGUTIL="/Library/Apple/usr/bin/cfgutil"
elif [ -x "/usr/local/bin/cfgutil" ]; then
  CFGUTIL="/usr/local/bin/cfgutil"
fi

LOG_DIR="$HOME/mac-restore-logs"
IPSW_DIR="${IPSW_DIR:-$HOME/Downloads}"
PARALLEL_MAX="${PARALLEL_MAX:-4}"
POLL_INTERVAL=5
SELECTED_IPSW=""

# ─── Banner ───────────────────────────────────────────────────────────────────
banner() {
  echo -e "${BOLD}${CYAN}"
  echo "  ╔═══════════════════════════════════════════════════╗"
  echo "  ║        Mac Restore Tool — Apple Silicon           ║"
  echo "  ║        Powered by Apple Configurator 2            ║"
  echo "  ╚═══════════════════════════════════════════════════╝${NC}"
  echo ""
}

# ─── Logging ──────────────────────────────────────────────────────────────────
mkdir -p "$LOG_DIR"
SESSION_LOG="$LOG_DIR/session_$(date +%Y%m%d_%H%M%S).log"

log()     { echo -e "$(date '+%H:%M:%S') $*" | tee -a "$SESSION_LOG"; }
log_ok()  { log "${GREEN}✓${NC}  $*"; }
log_err() { log "${RED}✗${NC}  $*"; }
log_inf() { log "${BLUE}ℹ${NC}  $*"; }
log_wrn() { log "${YELLOW}⚠${NC}  $*"; }

# ─── Checks de prerequisitos ──────────────────────────────────────────────────
check_prerequisites() {
  log_inf "Verificando prerequisitos..."

  if [ "$(uname)" != "Darwin" ]; then
    log_err "Este script solo funciona en macOS."; exit 1
  fi

  if [ -z "$CFGUTIL" ] || [ ! -x "$CFGUTIL" ]; then
    log_err "cfgutil no encontrado."
    echo -e "  ${YELLOW}→ Instala Apple Configurator 2 desde la App Store${NC}"
    echo -e "  ${YELLOW}→ Luego: Apple Configurator 2 > Menú > Instalar Herramientas de Automatización${NC}"
    exit 1
  fi
  log_ok "cfgutil: $CFGUTIL"

  if ! sudo -n true 2>/dev/null; then
    log_wrn "Se requieren permisos de administrador."
    sudo -v || { log_err "No se pudo autenticar."; exit 1; }
  fi
  log_ok "Permisos de administrador OK"
}

# ─── Selección de IPSW ────────────────────────────────────────────────────────
select_ipsw() {
  log_inf "Buscando archivos IPSW en: $IPSW_DIR"

  IPSW_FILES=()
  while IFS= read -r line; do
    if [ -n "$line" ]; then
      IPSW_FILES+=("$line")
    fi
  done < <(find "$IPSW_DIR" -maxdepth 3 -name "*.ipsw" 2>/dev/null | sort)

  if [ ${#IPSW_FILES[@]} -eq 0 ]; then
    log_err "No se encontraron archivos .ipsw en $IPSW_DIR"
    echo -e "  ${YELLOW}→ Descarga el IPSW desde: https://ipsw.me${NC}"
    echo -e "  ${YELLOW}→ O especifica la ruta: IPSW_DIR=/ruta/a/carpeta ./restore.sh${NC}"
    exit 1
  fi

  if [ ${#IPSW_FILES[@]} -eq 1 ]; then
    SELECTED_IPSW="${IPSW_FILES[0]}"
    log_ok "IPSW encontrado: $(basename "$SELECTED_IPSW")"
    return
  fi

  echo -e "\n${BOLD}Archivos IPSW disponibles:${NC}"
  local i=0
  while [ $i -lt ${#IPSW_FILES[@]} ]; do
    SIZE=$(du -h "${IPSW_FILES[$i]}" 2>/dev/null | cut -f1)
    echo -e "  ${CYAN}[$((i+1))]${NC} $(basename "${IPSW_FILES[$i]}") ${YELLOW}($SIZE)${NC}"
    i=$((i+1))
  done

  echo ""
  while true; do
    printf "${BOLD}Selecciona el número del IPSW [1-${#IPSW_FILES[@]}]: ${NC}"
    read -r choice
    if echo "$choice" | grep -qE '^[0-9]+$' && [ "$choice" -ge 1 ] && [ "$choice" -le ${#IPSW_FILES[@]} ]; then
      SELECTED_IPSW="${IPSW_FILES[$((choice-1))]}"
      log_ok "IPSW seleccionado: $(basename "$SELECTED_IPSW")"
      break
    fi
    echo -e "${RED}Selección inválida.${NC}"
  done
}

# ─── Listar dispositivos en DFU ───────────────────────────────────────────────
get_dfu_devices() {
  # Filtra solo dispositivos en modo DFU (ignora iPhones, iPads u otros Macs normales)
  "$CFGUTIL" list 2>/dev/null | grep -i "DFU" || true
}

get_ecids() {
  # Usa modo párrafo (RS="") para procesar cada bloque de dispositivo por separado.
  # Solo extrae ECIDs de bloques que contengan "DFU" (ignora Macs/iPhones normales).
  "$CFGUTIL" list 2>/dev/null \
    | awk '
        BEGIN { RS="" }
        /DFU/ {
          n = split($0, lines, "\n")
          for (i = 1; i <= n; i++) {
            if (lines[i] ~ /ECID:/) {
              val = lines[i]
              sub(/.*ECID:[[:space:]]*/, "", val)
              sub(/[^0-9A-Fa-f].*/, "", val)
              if (length(val) > 0) print val
            }
          }
        }
      ' \
    || true
}

count_devices() {
  get_ecids | wc -l | tr -d ' \t'
}

# ─── Restore de un dispositivo ────────────────────────────────────────────────
restore_device() {
  local ecid="$1"
  local ipsw="$2"
  local device_log="$LOG_DIR/device_${ecid}_$(date +%H%M%S).log"

  log_inf "Iniciando restore — ECID: ${CYAN}${ecid}${NC}"

  if "$CFGUTIL" --ecid "$ecid" restore -I "$ipsw" >> "$device_log" 2>&1; then
    log_ok "Restore completado — ECID: ${CYAN}${ecid}${NC}"
    return 0
  else
    log_err "Restore FALLIDO — ECID: ${CYAN}${ecid}${NC} — ver: $device_log"
    return 1
  fi
}

# ─── Restore paralelo ─────────────────────────────────────────────────────────
restore_all_parallel() {
  local ipsw="$1"
  local success_count=0
  local fail_count=0
  local running=0
  # Arrays paralelos (bash 3.2 no tiene arrays asociativos)
  local pid_list
  local ecid_list
  pid_list=()
  ecid_list=()

  log_inf "Iniciando restore paralelo (máx $PARALLEL_MAX simultáneos)..."
  echo ""

  local ecids
  ecids=()
  while IFS= read -r line; do
    if [ -n "$line" ]; then
      ecids+=("$line")
    fi
  done < <(get_ecids)

  if [ ${#ecids[@]} -eq 0 ]; then
    log_wrn "No hay dispositivos en DFU mode conectados."
    return 1
  fi

  log_inf "Dispositivos detectados: ${BOLD}${#ecids[@]}${NC}"
  echo ""

  local queue
  queue=("${ecids[@]}")

  while [ ${#queue[@]} -gt 0 ] || [ $running -gt 0 ]; do

    # Lanzar trabajos hasta el límite
    while [ ${#queue[@]} -gt 0 ] && [ $running -lt $PARALLEL_MAX ]; do
      local ecid="${queue[0]}"
      queue=("${queue[@]:1}")

      restore_device "$ecid" "$ipsw" &
      local pid=$!
      ecid_list+=("$ecid")
      pid_list+=("$pid")
      running=$((running + 1))
      log_inf "  Proceso lanzado para ECID $ecid (PID: $pid)"
    done

    # Revisar procesos terminados
    local i=0
    while [ $i -lt ${#pid_list[@]} ]; do
      local pid="${pid_list[$i]}"
      if ! kill -0 "$pid" 2>/dev/null; then
        wait "$pid" && success_count=$((success_count + 1)) || fail_count=$((fail_count + 1))
        pid_list=("${pid_list[@]:0:$i}" "${pid_list[@]:$((i+1))}")
        ecid_list=("${ecid_list[@]:0:$i}" "${ecid_list[@]:$((i+1))}")
        running=$((running - 1))
      else
        i=$((i + 1))
      fi
    done

    sleep 1
  done

  echo ""
  echo -e "  ${BOLD}═══════════════ Resumen ═══════════════${NC}"
  echo -e "  ${GREEN}✓ Exitosos:  $success_count${NC}"
  if [ $fail_count -gt 0 ]; then
    echo -e "  ${RED}✗ Fallidos:  $fail_count${NC}"
  fi
  echo -e "  ${BLUE}  Logs en:   $LOG_DIR${NC}"
  echo -e "  ${BOLD}════════════════════════════════════════${NC}"
}

# ─── Modo monitor ─────────────────────────────────────────────────────────────
monitor_mode() {
  local ipsw="$1"
  seen_ecids=()

  log_inf "${BOLD}Modo Monitor activo${NC} — conecta Macs en DFU para restaurarlos automáticamente"
  log_inf "Presiona ${BOLD}Ctrl+C${NC} para detener."
  echo ""

  trap 'echo -e "\n${YELLOW}Monitor detenido.${NC}"; exit 0' INT

  while true; do
    local current_ecids
    current_ecids=()
    while IFS= read -r line; do
      if [ -n "$line" ]; then
        current_ecids+=("$line")
      fi
    done < <(get_ecids)

    local ecid
    for ecid in "${current_ecids[@]+"${current_ecids[@]}"}"; do
      if [ -n "$ecid" ]; then
        local already_seen=0
        local s
        for s in "${seen_ecids[@]+"${seen_ecids[@]}"}"; do
          if [ "$s" = "$ecid" ]; then
            already_seen=1
            break
          fi
        done
        if [ $already_seen -eq 0 ]; then
          seen_ecids+=("$ecid")
          log_ok "Nuevo dispositivo detectado: ${CYAN}${ecid}${NC}"
          restore_device "$ecid" "$ipsw" &
        fi
      fi
    done

    sleep "$POLL_INTERVAL"
  done
}

# ─── Instrucciones DFU ────────────────────────────────────────────────────────
show_dfu_instructions() {
  echo -e "${BOLD}${YELLOW}"
  echo "  ┌─────────────────────────────────────────────────────┐"
  echo "  │   Cómo poner un Mac Apple Silicon en DFU Mode       │"
  echo "  ├─────────────────────────────────────────────────────┤"
  echo "  │  1. Apaga el Mac completamente                       │"
  echo "  │  2. Conecta el cable USB-C al puerto más cercano     │"
  echo "  │     a la fuente de alimentación del Mac host         │"
  echo "  │  3. Mantén presionado el botón de encendido          │"
  echo "  │     por 10 segundos hasta que la pantalla permanezca │"
  echo "  │     negra (sin logo de Apple)                        │"
  echo "  │  4. El Mac host debería detectar un dispositivo DFU  │"
  echo "  └─────────────────────────────────────────────────────┘${NC}"
  echo ""
}

# ─── Menú principal ───────────────────────────────────────────────────────────
main_menu() {
  local ipsw="$1"

  while true; do
    echo -e "\n${BOLD}Dispositivos conectados:${NC}"
    device_count=$(count_devices)

    if [ "$device_count" -eq 0 ]; then
      echo -e "  ${YELLOW}Ninguno detectado en DFU mode${NC}"
    else
      echo -e "  ${GREEN}${BOLD}$device_count dispositivo(s) en DFU mode${NC}"
      get_dfu_devices | grep -v "^$" | sed 's/^/  /'
    fi

    echo ""
    echo -e "${BOLD}Opciones:${NC}"
    echo -e "  ${CYAN}[1]${NC} Restaurar todos los dispositivos conectados"
    echo -e "  ${CYAN}[2]${NC} Modo monitor (detecta y restaura automáticamente)"
    echo -e "  ${CYAN}[3]${NC} Mostrar instrucciones modo DFU"
    echo -e "  ${CYAN}[4]${NC} Refrescar lista de dispositivos"
    echo -e "  ${CYAN}[5]${NC} Ver logs recientes"
    echo -e "  ${CYAN}[q]${NC} Salir"
    echo ""

    printf "${BOLD}Selecciona una opción: ${NC}"
    read -r opt

    case "$opt" in
      1)
        if [ "$device_count" -eq 0 ]; then
          log_wrn "No hay dispositivos conectados en DFU mode."
        else
          echo -e "\n${YELLOW}⚠  ATENCIÓN: Se restaurarán $device_count Mac(s). Todos los datos serán eliminados.${NC}"
          printf "${BOLD}¿Confirmas? [s/N]: ${NC}"
          read -r confirm
          if [ "$confirm" = "s" ] || [ "$confirm" = "S" ]; then
            restore_all_parallel "$ipsw"
          fi
        fi
        ;;
      2) monitor_mode "$ipsw" ;;
      3) show_dfu_instructions ;;
      4) log_inf "Actualizando lista..." ;;
      5)
        echo -e "\n${BOLD}Logs recientes:${NC}"
        ls -lt "$LOG_DIR"/*.log 2>/dev/null | head -10 | sed 's/^/  /' || echo "  Sin logs aún."
        ;;
      q|Q) echo -e "\n${GREEN}Hasta luego.${NC}"; exit 0 ;;
      *) log_wrn "Opción inválida." ;;
    esac
  done
}

# ─── Entrypoint ───────────────────────────────────────────────────────────────
main() {
  banner
  check_prerequisites
  select_ipsw
  show_dfu_instructions

  log_inf "IPSW listo: ${BOLD}$(basename "$SELECTED_IPSW")${NC}"
  log_inf "Logs de sesión: $SESSION_LOG"

  main_menu "$SELECTED_IPSW"
}

main "$@"
