#!/usr/bin/env bash
# =============================================================================
#  mac-restore.sh — Restauración masiva de Macs Apple Silicon
#  Requiere: Apple Configurator 2 instalado + Macs en modo DFU
# =============================================================================

set -euo pipefail

# ─── Colores ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

# ─── Configuración ────────────────────────────────────────────────────────────
CFGUTIL=$(command -v cfgutil 2>/dev/null \
  || ls /Library/Apple/usr/bin/cfgutil /usr/local/bin/cfgutil 2>/dev/null | head -1 \
  || echo "")
LOG_DIR="$HOME/mac-restore-logs"
IPSW_DIR="${IPSW_DIR:-$HOME/Downloads}"          # Carpeta donde buscar IPSW
PARALLEL_MAX="${PARALLEL_MAX:-4}"                 # Máximo de restores simultáneos
POLL_INTERVAL=5                                   # Segundos entre checks de dispositivos

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

  # macOS
  if [[ "$(uname)" != "Darwin" ]]; then
    log_err "Este script solo funciona en macOS."; exit 1
  fi

  # cfgutil
  if [[ ! -x "$CFGUTIL" ]]; then
    log_err "cfgutil no encontrado en $CFGUTIL"
    echo -e "  ${YELLOW}→ Instala Apple Configurator 2 desde la App Store${NC}"
    echo -e "  ${YELLOW}→ Luego: Apple Configurator 2 > Menú > Instalar Herramientas de Automatización${NC}"
    exit 1
  fi
  log_ok "cfgutil encontrado: $($CFGUTIL version 2>/dev/null || echo 'OK')"

  # Permisos sudo (necesario para restore)
  if ! sudo -n true 2>/dev/null; then
    log_wrn "Se requieren permisos de administrador para el restore."
    sudo -v || { log_err "No se pudo autenticar."; exit 1; }
  fi
  log_ok "Permisos de administrador OK"
}

# ─── Selección de IPSW ────────────────────────────────────────────────────────
select_ipsw() {
  log_inf "Buscando archivos IPSW en: $IPSW_DIR"

  # Buscar IPSWs disponibles
  mapfile -t IPSW_FILES < <(find "$IPSW_DIR" -maxdepth 3 -name "*.ipsw" 2>/dev/null | sort)

  if [[ ${#IPSW_FILES[@]} -eq 0 ]]; then
    log_err "No se encontraron archivos .ipsw en $IPSW_DIR"
    echo -e "  ${YELLOW}→ Descarga el IPSW desde: https://ipsw.me${NC}"
    echo -e "  ${YELLOW}→ O especifica la ruta: IPSW_DIR=/ruta/a/carpeta ./restore.sh${NC}"
    exit 1
  fi

  if [[ ${#IPSW_FILES[@]} -eq 1 ]]; then
    SELECTED_IPSW="${IPSW_FILES[0]}"
    log_ok "IPSW encontrado: $(basename "$SELECTED_IPSW")"
    return
  fi

  # Múltiples IPSWs — mostrar menú
  echo -e "\n${BOLD}Archivos IPSW disponibles:${NC}"
  for i in "${!IPSW_FILES[@]}"; do
    SIZE=$(du -h "${IPSW_FILES[$i]}" 2>/dev/null | cut -f1)
    echo -e "  ${CYAN}[$((i+1))]${NC} $(basename "${IPSW_FILES[$i]}") ${YELLOW}($SIZE)${NC}"
  done

  echo ""
  while true; do
    read -rp "$(echo -e "${BOLD}Selecciona el número del IPSW [1-${#IPSW_FILES[@]}]: ${NC}")" choice
    if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#IPSW_FILES[@]} )); then
      SELECTED_IPSW="${IPSW_FILES[$((choice-1))]}"
      log_ok "IPSW seleccionado: $(basename "$SELECTED_IPSW")"
      break
    fi
    echo -e "${RED}Selección inválida.${NC}"
  done
}

# ─── Listar dispositivos conectados en DFU ────────────────────────────────────
get_dfu_devices() {
  # cfgutil list devuelve JSON; extraemos ECIDs y nombres
  "$CFGUTIL" list 2>/dev/null || true
}

get_ecids() {
  "$CFGUTIL" list 2>/dev/null \
    | grep -oE 'ECID:[[:space:]]*[0-9A-Fa-f]+' \
    | awk '{print $2}' \
    || true
}

count_devices() {
  get_ecids | wc -l | tr -d ' '
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

# ─── Restore paralelo de todos los dispositivos conectados ────────────────────
restore_all_parallel() {
  local ipsw="$1"
  declare -A pids=()       # ecid -> PID
  local success_count=0
  local fail_count=0

  log_inf "Iniciando restore paralelo (máx $PARALLEL_MAX simultáneos)..."
  echo ""

  mapfile -t ecids < <(get_ecids)

  if [[ ${#ecids[@]} -eq 0 ]]; then
    log_wrn "No hay dispositivos en DFU mode conectados."
    return 1
  fi

  log_inf "Dispositivos detectados: ${BOLD}${#ecids[@]}${NC}"
  echo ""

  # Cola de trabajos con control de paralelismo
  local running=0
  local queue=("${ecids[@]}")

  while [[ ${#queue[@]} -gt 0 ]] || [[ $running -gt 0 ]]; do

    # Lanzar trabajos hasta el límite
    while [[ ${#queue[@]} -gt 0 ]] && [[ $running -lt $PARALLEL_MAX ]]; do
      ecid="${queue[0]}"
      queue=("${queue[@]:1}")

      restore_device "$ecid" "$ipsw" &
      pids[$ecid]=$!
      (( running++ ))
      log_inf "  Proceso lanzado para ECID $ecid (PID: ${pids[$ecid]})"
    done

    # Esperar un trabajo que termine
    for ecid in "${!pids[@]}"; do
      pid="${pids[$ecid]}"
      if ! kill -0 "$pid" 2>/dev/null; then
        wait "$pid" && (( success_count++ )) || (( fail_count++ ))
        unset "pids[$ecid]"
        (( running-- ))
      fi
    done

    sleep 1
  done

  echo ""
  echo -e "  ${BOLD}═══════════════ Resumen ═══════════════${NC}"
  echo -e "  ${GREEN}✓ Exitosos:  $success_count${NC}"
  [[ $fail_count -gt 0 ]] && echo -e "  ${RED}✗ Fallidos:  $fail_count${NC}"
  echo -e "  ${BLUE}  Logs en:   $LOG_DIR${NC}"
  echo -e "  ${BOLD}════════════════════════════════════════${NC}"
}

# ─── Modo monitor: esperar nuevos dispositivos y restaurarlos auto ─────────────
monitor_mode() {
  local ipsw="$1"
  local seen_ecids=()

  log_inf "${BOLD}Modo Monitor activo${NC} — conecta Macs en DFU para restaurarlos automáticamente"
  log_inf "Presiona ${BOLD}Ctrl+C${NC} para detener.\n"

  trap 'echo -e "\n${YELLOW}Monitor detenido.${NC}"; exit 0' INT

  while true; do
    mapfile -t current_ecids < <(get_ecids)

    for ecid in "${current_ecids[@]}"; do
      if [[ -n "$ecid" ]] && [[ ! " ${seen_ecids[*]} " =~ " ${ecid} " ]]; then
        seen_ecids+=("$ecid")
        log_ok "Nuevo dispositivo detectado: ${CYAN}${ecid}${NC}"
        restore_device "$ecid" "$ipsw" &
      fi
    done

    sleep "$POLL_INTERVAL"
  done
}

# ─── Mostrar instrucciones DFU ─────────────────────────────────────────────────
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

    if [[ "$device_count" -eq 0 ]]; then
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

    read -rp "$(echo -e "${BOLD}Selecciona una opción: ${NC}")" opt

    case "$opt" in
      1)
        if [[ "$device_count" -eq 0 ]]; then
          log_wrn "No hay dispositivos conectados en DFU mode."
        else
          echo -e "\n${YELLOW}⚠  ATENCIÓN: Se restaurarán $device_count Mac(s). Todos los datos serán eliminados.${NC}"
          read -rp "$(echo -e "${BOLD}¿Confirmas? [s/N]: ${NC}")" confirm
          [[ "$confirm" =~ ^[sS]$ ]] && restore_all_parallel "$ipsw"
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
