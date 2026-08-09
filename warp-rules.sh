#!/usr/bin/env bash
#
# warp-rules.sh — инструмент для серверов Xray/VLESS
#
# Меню:
#   1. Анализ сервера + генерация блока маршрутизации для WARP.
#   2. Предварительная проверка пригодности WARP (до установки, с очисткой).
#   3. Установка инструментов (Remnawave / rw-backup / Multitest).
#   4. Оптимизация и защита ноды — обёртка над node-accelerator
#      (github.com/jestivald/node-accelerator): XanMod/BBRv3, sysctl,
#      nftables + CrowdSec, блоклисты, откат.
#   5. Обновление системы + фикс при сбоях (диагностика apt update,
#      автофикс известных ошибок при необходимости, затем apt upgrade -y).
#   6. Обновление / откат ноды Remnawave (выбор версии с GitHub, без потери
#      настроек docker-compose).
#   7. Обновление / откат Xray-Core без обновления ноды (меняет только
#      бинарник xray внутри контейнера ноды, образ Node не трогает).
#
# Запуск:
#   bash <(curl -fsSL .../warp-rules.sh)        # покажет меню
#   bash warp-rules.sh 1                          # сразу режим 1
#   bash warp-rules.sh 2                          # сразу режим 2
#   bash warp-rules.sh 3                          # сразу режим 3
#   bash warp-rules.sh 5                          # сразу режим 5
#   bash warp-rules.sh 5 --auto                   # режим 5 без интерактивных вопросов (cron)
#   bash warp-rules.sh 6                          # сразу режим 6
#   bash warp-rules.sh 7                          # сразу режим 7
#   bash warp-rules.sh 1 -- -t 5                  # аргументы после -- уходят в ipregion

set -uo pipefail

# =========================== НАСТРОЙКИ =====================================
SCRIPT_VERSION="2.0.0"
WARP_TAG="warp-out"
IPREGION_URL="https://ipregion.vrnt.xyz"
IPREGION_LOCAL="./ipregion.sh"
IPREGION_TIMEOUT=90
WGCF_URL="https://github.com/ViRb3/wgcf/releases/download/v2.2.22/wgcf_2.2.22_linux_amd64"
BAD_COUNTRIES=("RU" "CN" "IR" "KP" "SY" "CU")
SKIP_SERVICES=("YouTube" "YouTube Premium" "YouTube CDN")

declare -A SERVICE_DOMAINS=(
  ["Google"]="geosite:google-gemini,domain:gemini.google.com,domain:ai.google.dev,domain:aistudio.google.com,domain:makersuite.google.com,domain:generativelanguage.googleapis.com,domain:labs.google,domain:aisandbox-pa.googleapis.com"
  ["Gemini Supported"]="geosite:google-gemini,domain:gemini.google.com,domain:ai.google.dev,domain:aistudio.google.com,domain:makersuite.google.com,domain:generativelanguage.googleapis.com,domain:labs.google,domain:aisandbox-pa.googleapis.com"
  ["ChatGPT"]="geosite:openai"
  ["Netflix"]="geosite:netflix"
  ["Spotify"]="geosite:spotify"
  ["Tiktok"]="geosite:tiktok,domain:byteoversea.com,domain:musical.ly"
  ["Reddit"]="geosite:reddit,domain:reddit.com,domain:redd.it"
  ["Disney+"]="geosite:disney,domain:disneyplus.com,domain:disney-plus.net,domain:dssott.com"
  ["Twitch"]="geosite:twitch,domain:twitch.tv,domain:ttvnw.net"
  ["Apple"]="domain:apple.com"
  ["Steam"]="geosite:steam,domain:steampowered.com,domain:steamcommunity.com"
  ["PlayStation"]="domain:playstation.com"
  ["Microsoft"]="domain:bing.com,domain:copilot.microsoft.com"
  ["JetBrains"]="domain:jetbrains.com"
)

# =========================== УТИЛИТЫ =======================================
c_red(){ printf '\033[1;31m%s\033[0m' "$1"; }
c_grn(){ printf '\033[1;32m%s\033[0m' "$1"; }
c_yel(){ printf '\033[1;33m%s\033[0m' "$1"; }
c_cyn(){ printf '\033[1;36m%s\033[0m' "$1"; }
msg(){ printf '%s\n' "$*" >&2; }
need(){ command -v "$1" >/dev/null 2>&1; }
in_list(){ local x="$1"; shift; local i; for i in "$@"; do [[ "$i" == "$x" ]] && return 0; done; return 1; }

# текущая версия ноды remnanode + xray, напр. "2.7.0 (xray 1.8.4)". Пусто, если ноды нет.
remnanode_status(){
  need docker || return 1
  local img tag xver
  img=$(docker inspect remnanode --format '{{.Config.Image}}' 2>/dev/null) || return 1
  [[ -z "$img" ]] && return 1
  tag="${img##*:}"
  xver=$(docker exec remnanode xray version 2>/dev/null | awk 'NR==1{print $2}')
  printf '%s%s' "$tag" "${xver:+ (xray $xver)}"
}

# спиннер: крутится, пока жив процесс $1, рядом текст $2
spinner(){
  local pid="$1" text="$2"
  local spin='|/-\'
  local i=0
  while kill -0 "$pid" 2>/dev/null; do
    i=$(( (i+1) % 4 ))
    printf '\r%s %s' "$(c_cyn "${spin:$i:1}")" "$text" >&2
    sleep 0.15
  done
  printf '\r\033[K' >&2   # стереть строку спиннера
}

# крутить спиннер заданное число секунд (для sleep-ожиданий)
spin_sleep(){
  local secs="$1" text="$2"
  ( sleep "$secs" ) &
  spinner "$!" "$text"
  wait 2>/dev/null
}

# =========================== ОБЩЕЕ: ipregion ==============================
ipregion_args=()
parse_ipregion_args(){
  # если среди аргументов есть "--", всё после него уходит в ipregion
  local seen=false a
  for a in "$@"; do
    if $seen; then ipregion_args+=("$a"); fi
    [[ "$a" == "--" ]] && seen=true
  done
}

run_ipregion(){
  if [[ -f "$IPREGION_LOCAL" ]]; then
    timeout "$IPREGION_TIMEOUT" bash "$IPREGION_LOCAL" -j "${ipregion_args[@]}"
  else
    timeout "$IPREGION_TIMEOUT" bash <(curl -fsSL "$IPREGION_URL") -j "${ipregion_args[@]}"
  fi
}

# =========================== РЕЖИМ 1: АНАЛИЗ ==============================
mode_analyze(){
  if ! need curl; then msg "$(c_red '[!] curl не установлен')"; return 1; fi

  msg "$(c_cyn '[*] Проверяю сервер через ipregion (~10-30 сек)...')"
  local JSON rc tmpf
  tmpf="$(mktemp)"
  run_ipregion > "$tmpf" 2>/dev/null &
  spinner "$!" "Опрашиваю GeoIP-сервисы..."
  wait "$!" 2>/dev/null; rc=$?
  JSON="$(cat "$tmpf")"; rm -f "$tmpf"
  if [[ $rc -eq 124 ]]; then
    msg "$(c_red "[!] ipregion завис и прерван по таймауту (${IPREGION_TIMEOUT}с).")"
    msg "$(c_red '    Часть GeoIP-сервисов не отвечает. Запусти позже или с коротким -t:')"
    msg "$(c_red '    выбери пункт 1 и передай: -- -t 5')"
    return 1
  fi

  if ! need jq; then msg "$(c_red '[!] jq не найден. Установи: apt install -y jq')"; return 1; fi
  if ! jq -e . >/dev/null 2>&1 <<<"$JSON"; then
    msg "$(c_red '[!] ipregion вернул не-JSON:')"; msg "$JSON"; return 1
  fi

  # страна сервера по консенсусу
  local SERVER_COUNTRY VOTES
  SERVER_COUNTRY="$(jq -r '(.results.primary // [])[] | .ipv4 // empty' <<<"$JSON" \
    | grep -oE '[A-Z]{2}' | sort | uniq -c | sort -rn | head -1 | awk '{print $2}')"
  VOTES="$(jq -r '(.results.primary // [])[] | .ipv4 // empty' <<<"$JSON" \
    | grep -oE '[A-Z]{2}' | sort | uniq -c | sort -rn | awk '{printf "%s×%s ", $2, $1}')"

  if [[ -z "$SERVER_COUNTRY" ]]; then
    msg "$(c_red '[!] Не удалось определить страну сервера.')"; return 1
  fi

  msg ""
  msg "$(c_cyn '[*] Страна сервера (консенсус):') $(c_grn "$SERVER_COUNTRY")  $(c_yel "[голоса: $VOTES]")"
  local SERVER_IS_RU=false
  [[ "$SERVER_COUNTRY" == "RU" ]] && SERVER_IS_RU=true
  $SERVER_IS_RU && msg "$(c_yel '    Сервер сам определяется как Россия — проверю, спасает ли WARP.')"

  # сломанные сервисы
  local -a ROWS
  mapfile -t ROWS < <(jq -r '(.results.custom // [])[] | "\(.service)\t\(.ipv4 // "")"' <<<"$JSON")
  declare -A BROKEN_DOMAINS=()
  local -a BROKEN_REPORT=()
  local row name value domains broken reason d
  for row in "${ROWS[@]}"; do
    name="${row%%$'\t'*}"; value="${row#*$'\t'}"
    in_list "$name" "${SKIP_SERVICES[@]}" && continue
    domains="${SERVICE_DOMAINS[$name]:-}"; [[ -z "$domains" ]] && continue
    broken=false; reason=""
    if [[ "$value" == "No" ]]; then broken=true; reason="недоступен (No)"
    elif [[ "$value" == "RU" ]]; then broken=true; reason="определяется как Россия"; fi
    if $broken; then
      BROKEN_REPORT+=("$name — $reason")
      IFS=',' read -ra arr <<<"$domains"
      for d in "${arr[@]}"; do [[ -n "$d" ]] && BROKEN_DOMAINS["$d"]=1; done
    fi
  done

  if ! $SERVER_IS_RU && [[ ${#BROKEN_DOMAINS[@]} -eq 0 ]]; then
    msg ""; msg "$(c_grn '[OK] Сервер не Россия и сломанных сервисов нет — WARP не нужен.')"; return 0
  fi
  if [[ ${#BROKEN_DOMAINS[@]} -gt 0 ]]; then
    msg ""; msg "$(c_yel '[!] Сломанные сервисы:')"
    local r; for r in "${BROKEN_REPORT[@]}"; do msg "      - $r"; done
  fi

  # проверка установленного WARP
  local WARP_IF="" WARP_OK="unknown" WARP_LOC="" WARP_COLO="" WARP_IP=""
  if need wg; then
    WARP_IF="$(wg show interfaces 2>/dev/null | tr ' ' '\n' | grep -v '^$' | head -1)"
  fi

  if [[ -z "$WARP_IF" ]]; then
    msg ""
    if need wg; then
      msg "$(c_yel '[!] WARP не поднят (интерфейс отсутствует).')"
    else
      msg "$(c_yel '[!] wireguard-tools не установлен — проверить WARP нечем.')"
      msg "$(c_yel '    Для проверки WARP используй пункт 2 меню.')"
    fi
  else
    msg ""
    msg "$(c_cyn '[*] Найден WARP-интерфейс: ')$(c_grn "$WARP_IF")$(c_cyn '. Проверяю туннель...')"
    local WG_DUMP HAS_HS=false RX
    WG_DUMP="$(wg show "$WARP_IF" 2>/dev/null)"
    grep -q 'latest handshake' <<<"$WG_DUMP" && HAS_HS=true
    RX="$(grep -oE 'transfer: [0-9.]+ [KMGT]?i?B received' <<<"$WG_DUMP" | grep -oE '[0-9.]+ [KMGT]?i?B' | head -1)"
    if ! $HAS_HS && [[ "$RX" == "0 B" || -z "$RX" ]]; then
      msg "$(c_red '[!] WARP-туннель не поднялся: нет рукопожатия, 0 байт от Cloudflare.')"
      msg "$(c_red '    Трафик до Cloudflare блокируется (типично для серверов в России).')"
      WARP_OK="dead"
    else
      msg "$(c_cyn '    Туннель живой. Проверяю страну выхода...')"
      local TRACE
      TRACE="$(curl --interface "$WARP_IF" -s --max-time 12 https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null)"
      WARP_LOC="$(grep -oE '^loc=[A-Z]{2}' <<<"$TRACE" | cut -d= -f2)"
      WARP_COLO="$(grep -oE '^colo=[A-Z]{3}' <<<"$TRACE" | cut -d= -f2)"
      WARP_IP="$(grep -oE '^ip=[0-9a-fA-F:.]+' <<<"$TRACE" | cut -d= -f2)"
      if [[ -z "$WARP_LOC" ]]; then
        msg "$(c_red '[!] Туннель поднят, но выход не отвечает.')"
      else
        msg "$(c_cyn '    WARP выходит как:') $(c_grn "$WARP_LOC")  $(c_yel "(дата-центр: ${WARP_COLO:-?}, IP: ${WARP_IP:-?})")"
        if in_list "$WARP_LOC" "${BAD_COUNTRIES[@]}"; then WARP_OK="bad"; else WARP_OK="good"; fi
      fi
    fi
  fi

  # вердикт
  if $SERVER_IS_RU; then
    if [[ "$WARP_OK" == "good" ]]; then
      msg ""; msg "$(c_grn "[OK] Сервер Россия, но WARP выходит как $WARP_LOC — спасаемо через WARP.")"
    else
      msg ""
      msg "$(c_red '======================================================')"
      if [[ "$WARP_OK" == "dead" ]]; then
        msg "$(c_red '[!] Сервер Россия, и WARP-туннель не поднимается.')"
      else
        msg "$(c_red '[!] Сервер определяется как Россия, и WARP не спасает')"
        msg "$(c_red "    (WARP: ${WARP_LOC:-нет/недоступен}).")"
      fi
      msg "$(c_red '    Работа невозможна. Сервер для задачи не подходит.')"
      msg "$(c_red '======================================================')"
      return 2
    fi
  fi

  if [[ "$WARP_OK" == "bad" ]]; then
    msg ""
    msg "$(c_red "[!] WARP выходит в нерабочую страну ($WARP_LOC) — чинить бесполезно.")"
    msg "$(c_red '    Нужен другой выход. Блок ниже работать не будет.')"
    return 3
  fi
  if [[ "$WARP_OK" == "dead" ]]; then
    msg ""
    msg "$(c_red '[!] WARP-туннель не работает — сломанные сервисы не починятся.')"
    msg "$(c_red '    Подними WARP (смени endpoint/порт) и запусти снова.')"
    return 3
  fi

  if [[ ${#BROKEN_DOMAINS[@]} -eq 0 ]]; then
    msg ""; msg "$(c_grn '[OK] Чинить нечего.')"; return 0
  fi

  msg ""
  if [[ "$WARP_OK" == "good" ]]; then
    msg "$(c_cyn '[*] Готовый блок для routing.rules (вставь ВЫШЕ дефолтного маршрута):')"
  else
    msg "$(c_yel '[*] Предварительный блок (WARP не подтверждён — проверь страну WARP сам!):')"
  fi
  msg ""
  local -a SORTED
  mapfile -t SORTED < <(printf '%s\n' "${!BROKEN_DOMAINS[@]}" | sort)
  printf '%s\n' "${SORTED[@]}" | jq -R . | jq -s --arg tag "$WARP_TAG" '{type:"field", domain:., outboundTag:$tag}'
}

# =========================== РЕЖИМ 2: ТЕСТ WARP ===========================
mode_test_warp(){
  if ! need curl; then msg "$(c_red '[!] curl не установлен')"; return 1; fi

  msg "$(c_cyn '[*] Предварительная проверка пригодности WARP...')"
  msg "$(c_cyn '    (поднимаю временный туннель, потом всё удалю)')"

  # запомнить, что было до теста — чтобы вычистить за собой
  WT_HAD_WG=false; need wg && WT_HAD_WG=true
  WT_TMPD="$(mktemp -d)"
  WT_IFACE="wgtest_$$"
  WT_CONF="/etc/wireguard/${WT_IFACE}.conf"

  cleanup(){
    [[ -n "${WT_CLEANED:-}" ]] && return
    WT_CLEANED=1
    wg-quick down "${WT_IFACE:-}" >/dev/null 2>&1
    [[ -n "${WT_CONF:-}" ]] && rm -f "$WT_CONF"
    [[ -n "${WT_TMPD:-}" ]] && rm -rf "$WT_TMPD"
    if [[ "${WT_HAD_WG:-true}" == "false" ]]; then apt-get remove -y wireguard-tools >/dev/null 2>&1; fi
    msg "$(c_cyn '[*] Временные файлы и пакеты удалены — сервер чист.')"
  }
  trap cleanup RETURN

  # установить wireguard-tools при необходимости
  if ! need wg; then
    msg "$(c_cyn '    Устанавливаю wireguard-tools (временно)...')"
    apt-get install -y wireguard-tools >/dev/null 2>&1
    if ! need wg; then msg "$(c_red '[!] Не удалось установить wireguard-tools.')"; return 1; fi
  fi

  # скачать wgcf
  msg "$(c_cyn '    Получаю профиль WARP (wgcf)...')"
  if ! curl -fsSL "$WGCF_URL" -o "$WT_TMPD/wgcf" 2>/dev/null; then
    msg "$(c_red '[!] Не удалось скачать wgcf.')"; return 1
  fi
  chmod +x "$WT_TMPD/wgcf"
  ( cd "$WT_TMPD" && ./wgcf register --accept-tos >/dev/null 2>&1 && ./wgcf generate >/dev/null 2>&1 )
  if [[ ! -f "$WT_TMPD/wgcf-profile.conf" ]]; then
    msg "$(c_red '[!] Не удалось сгенерировать профиль WARP.')"; return 1
  fi

  cp "$WT_TMPD/wgcf-profile.conf" "$WT_CONF"
  wg-quick up "$WT_IFACE" >/dev/null 2>&1
  spin_sleep 6 "Жду рукопожатия с Cloudflare..."

  msg ""
  msg "$(c_cyn '=== Результат проверки ===')"
  local WG_DUMP HAS_HS=false RX
  WG_DUMP="$(wg show "$WT_IFACE" 2>/dev/null)"
  grep -q 'latest handshake' <<<"$WG_DUMP" && HAS_HS=true
  RX="$(grep -oE 'transfer: [0-9.]+ [KMGT]?i?B received' <<<"$WG_DUMP" | grep -oE '[0-9.]+ [KMGT]?i?B' | head -1)"

  if ! $HAS_HS; then
    msg "$(c_red '[✗] WARP НЕ РАБОТАЕТ — сервер не подходит.')"
    msg "$(c_red "    Рукопожатие с Cloudflare не состоялось (получено: ${RX:-0 B}).")"
    msg "$(c_red '    UDP-трафик до Cloudflare блокируется. Возьми другой сервер.')"
    return 2
  fi

  # туннель жив — проверим страну
  local TRACE WARP_LOC WARP_COLO WARP_IP
  TRACE="$(curl --interface "$WT_IFACE" -s --max-time 12 https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null)"
  WARP_LOC="$(grep -oE '^loc=[A-Z]{2}' <<<"$TRACE" | cut -d= -f2)"
  WARP_COLO="$(grep -oE '^colo=[A-Z]{3}' <<<"$TRACE" | cut -d= -f2)"
  WARP_IP="$(grep -oE '^ip=[0-9a-fA-F:.]+' <<<"$TRACE" | cut -d= -f2)"

  msg "$(c_grn '[✓] WARP РАБОТАЕТ — рукопожатие установлено.')"
  if [[ -n "$WARP_LOC" ]]; then
    msg "$(c_cyn '    Страна выхода:') $(c_grn "$WARP_LOC")  $(c_yel "(дата-центр: ${WARP_COLO:-?}, IP: ${WARP_IP:-?})")"
    if in_list "$WARP_LOC" "${BAD_COUNTRIES[@]}"; then
      msg "$(c_red "[!] Но WARP выходит как $WARP_LOC — это нерабочая страна, толку не будет.")"
      return 3
    else
      msg "$(c_grn "[OK] Страна $WARP_LOC рабочая — сервер ГОДЕН для WARP.")"
    fi
  else
    msg "$(c_yel '    Страну выхода определить не удалось, но туннель живой.')"
  fi
  return 0
}

# =========================== ДАШБОРД MOTD ==================================
update_motd(){
  cat > /etc/update-motd.d/99-remnawave-hint << 'MOTD_EOF'
#!/bin/sh
YEL='\033[1;33m'
GRN='\033[1;32m'
LBLU='\033[1;34m'
RED='\033[1;31m'
RST='\033[0m'
command -v remnawave_reverse >/dev/null 2>&1 && \
  printf "${YEL}⚡️ Быстрый запуск скрипта EGames:${RST}     ${GRN}remnawave_reverse${RST} (или ${GRN}rr${RST})\n"
command -v rw-backup >/dev/null 2>&1 && \
  printf "${YEL}⚡️ Быстрый запуск бэкапов Remnawave:${RST}  ${GRN}rw-backup${RST}\n"
command -v multitest >/dev/null 2>&1 && \
  printf "${YEL}⚡️ Быстрый запуск тестов:${RST}             ${LBLU}multitest${RST}\n"
if command -v wrules >/dev/null 2>&1 && grep -q 'warp-rules' "$(command -v wrules)" 2>/dev/null; then
  printf "${YEL}⚡️ Быстрый запуск WARP Rules:${RST}         ${RED}wrules${RST}\n"
fi
_wn=false
if [ -f /opt/warp-native/warp-watchdog.sh ]; then
  _wn=true
elif command -v warp >/dev/null 2>&1; then
  case "$(cat "$(command -v warp)" 2>/dev/null)" in *warp-rules*) ;; *) _wn=true ;; esac
fi
if $_wn; then
  if wg show warp 2>/dev/null | grep -q 'latest handshake'; then
    printf "${YEL}⚡️ WARP Native (distillium):${RST} ${GRN}активен${RST} — warp\n"
  else
    printf "${YEL}⚡️ WARP Native (distillium):${RST} ${RED}не активен${RST} — warp\n"
  fi
fi
printf "\n"
MOTD_EOF
  chmod +x /etc/update-motd.d/99-remnawave-hint
}

# =========================== РЕЖИМ 3: ИНСТРУМЕНТЫ ==========================
mode_install_tools(){
  while :; do
    local has_remnawave=false has_rwbackup=false has_multitest=false
    command -v remnawave_reverse >/dev/null 2>&1 && has_remnawave=true
    command -v rw-backup         >/dev/null 2>&1 && has_rwbackup=true
    command -v multitest         >/dev/null 2>&1 && has_multitest=true

    local -a KEYS=() LABELS=()
    $has_remnawave    || { KEYS+=("remnawave");    LABELS+=("Remnawave"); }
    $has_rwbackup     || { KEYS+=("rw-backup");    LABELS+=("rw-backup (бэкапы Remnawave)"); }
    $has_multitest    || { KEYS+=("multitest");    LABELS+=("Multitest"); }

    msg ""
    msg "$(c_cyn '──── Установка инструментов ────')"
    $has_remnawave    && msg "  $(c_grn '[✓]') Remnawave"
    $has_rwbackup     && msg "  $(c_grn '[✓]') rw-backup"
    $has_multitest    && msg "  $(c_grn '[✓]') Multitest"

    if [[ ${#KEYS[@]} -gt 0 ]]; then
      local any_inst=false
      $has_remnawave || $has_rwbackup || $has_multitest \
        && any_inst=true
      $any_inst && msg ""
      local i
      for (( i=0; i<${#KEYS[@]}; i++ )); do
        msg "  $(( i+1 )). ${LABELS[$i]}"
      done
    fi
    msg "  0. Назад"
    msg "$(c_cyn '────────────────────────────────────')"
    [[ ${#KEYS[@]} -eq 0 ]] && msg "$(c_grn '[✓] Все инструменты установлены.')"

    printf '%s' "$(c_yel '[?] Выбор: ')" >&2
    local choice
    read -r choice < /dev/tty 2>/dev/null || return 1

    [[ "$choice" == "0" ]] && return 0
    [[ ${#KEYS[@]} -eq 0 ]] && continue

    if ! [[ "$choice" =~ ^[0-9]+$ ]] || \
       (( choice < 1 || choice > ${#KEYS[@]} )); then
      msg "$(c_red 'Неверный выбор, повтори.')"
      continue
    fi

    local key="${KEYS[$(( choice - 1 ))]}"
    case "$key" in
      remnawave)
        msg "$(c_cyn '[*] Устанавливаю Remnawave...')"
        if { cat > /usr/local/bin/remnawave_reverse << 'WRAPPER'
#!/usr/bin/env bash
bash <(curl -fsSL https://raw.githubusercontent.com/eGamesAPI/remnawave-reverse-proxy/refs/heads/main/install_remnawave.sh) "$@"
WRAPPER
        } && chmod +x /usr/local/bin/remnawave_reverse \
          && ln -sf /usr/local/bin/remnawave_reverse /usr/local/bin/rr; then
          msg "$(c_grn '[✓] Remnawave установлен.')"
          update_motd
        else
          msg "$(c_red '[✗] Ошибка установки Remnawave.')"
        fi
        ;;
      rw-backup)
        msg "$(c_cyn '[*] Устанавливаю rw-backup...')"
        if { cat > /usr/local/bin/rw-backup << 'WRAPPER'
#!/usr/bin/env bash
bash <(curl -fsSL https://raw.githubusercontent.com/distillium/remnawave-backup-restore/main/backup-restore.sh) "$@"
WRAPPER
        } && chmod +x /usr/local/bin/rw-backup; then
          msg "$(c_grn '[✓] rw-backup установлен.')"
          update_motd
        else
          msg "$(c_red '[✗] Ошибка установки rw-backup.')"
        fi
        ;;
      multitest)
        msg "$(c_cyn '[*] Устанавливаю Multitest...')"
        if { cat > /usr/local/bin/multitest << 'WRAPPER'
#!/usr/bin/env bash
bash <(curl -fsSL https://raw.githubusercontent.com/saveksme/multitest/master/multitest.sh) "$@"
WRAPPER
        } && chmod +x /usr/local/bin/multitest; then
          msg "$(c_grn '[✓] Multitest установлен.')"
          update_motd
        else
          msg "$(c_red '[✗] Ошибка установки Multitest.')"
        fi
        ;;
    esac
  done
}

# =========================== АЛИАС wrules ====================================
install_warp_alias(){
  local target="/usr/local/bin/wrules"
  # Наш файл уже есть — пропускаем
  [[ -f "$target" ]] && grep -q 'warp-rules' "$target" 2>/dev/null && return 0
  # Чужой файл с таким именем — не трогаем
  [[ -f "$target" ]] && return 1
  # В PATH есть wrules, но не наш — не трогаем
  command -v wrules >/dev/null 2>&1 && return 1
  # Создаём
  cat > "$target" << 'EOF'
#!/usr/bin/env bash
export WRULES_INVOKED=1
bash <(curl -fsSL https://raw.githubusercontent.com/9333003/warp-rules/main/warp-rules.sh) "$@"
EOF
  chmod +x "$target"
}

# при запуске через wrules скрипт всегда curl'ится заново (свежий с GitHub),
# поэтому "проверка обновления" — это сравнение версии с прошлым запуском
check_for_update(){
  local state_file="${HOME}/.warp-rules-last-version"
  local prev=""
  [[ -f "$state_file" ]] && prev="$(cat "$state_file" 2>/dev/null)"
  if [[ -n "$prev" && "$prev" != "$SCRIPT_VERSION" ]]; then
    msg "$(c_grn "[✓] warp-rules обновлён: v${prev} → v${SCRIPT_VERSION}")"
    msg ""
  fi
  printf '%s' "$SCRIPT_VERSION" > "$state_file" 2>/dev/null
}

# =========================== БЫСТРЫЕ КОМАНДЫ ==============================
show_hints(){
  local any=false
  command -v remnawave_reverse >/dev/null 2>&1 && { any=true
    msg "$(c_yel '⚡️ Быстрый запуск скрипта EGames:') $(c_grn 'remnawave_reverse')  (или $(c_grn 'rr'))"; }
  command -v rw-backup >/dev/null 2>&1 && { any=true
    msg "$(c_yel '⚡️ Быстрый запуск бэкапов Remnawave:') $(c_grn 'rw-backup')"; }
  command -v multitest >/dev/null 2>&1 && { any=true
    msg "$(c_yel '⚡️ Быстрый запуск тестов:') $(c_cyn 'multitest')"; }
  command -v wrules >/dev/null 2>&1 \
    && grep -q 'warp-rules' "$(command -v wrules)" 2>/dev/null && { any=true
    msg "$(c_yel '⚡️ Быстрый запуск WARP Rules:') $(c_red 'wrules')"; }
  local _warp_native=false
  if [[ -f /opt/warp-native/warp-watchdog.sh ]]; then
    _warp_native=true
  elif command -v warp >/dev/null 2>&1 && ! grep -q 'warp-rules' "$(command -v warp)" 2>/dev/null; then
    _warp_native=true
  fi
  if $_warp_native; then
    any=true
    if wg show warp 2>/dev/null | grep -q 'latest handshake'; then
      msg "$(c_yel '⚡️ WARP Native (distillium):') $(c_grn 'активен') — warp"
    else
      msg "$(c_yel '⚡️ WARP Native (distillium):') $(c_red 'не активен') — warp"
    fi
  fi
  $any && msg ""
}

# =========================== МЕНЮ =========================================
# Единый источник нумерации меню (8.2 ТЗ): номер → функция/подпись,
# используется и в быстром запуске по аргументу, и в интерактивном цикле —
# при перенумерации правится только здесь.
declare -A MENU_FUNCS=(
  [1]=mode_analyze
  [2]=mode_test_warp
  [3]=mode_install_tools
  [4]=mode_na_hardening
  [5]=fix_and_update
  [6]=mode_remnanode_update
  [7]=mode_xray_update
)
declare -A MENU_LABELS=(
  [1]="Анализ сервера + блок для конфига"
  [2]="Проверка пригодности WARP (до установки)"
  [3]="Установка инструментов"
  [4]="Оптимизация и защита ноды"
  [5]="Обновление системы + фикс при сбоях"
  [6]="Обновление / откат ноды Remnawave"
  [7]="Обновление / откат Xray-Core (без обновления ноды)"
)
MENU_ORDER=(1 2 3 4 5 6 7)
# пункты, которые в интерактивном меню сразу завершают скрипт (как при быстром запуске)
MENU_EXIT_AFTER=(1 2)

show_menu(){
  msg ""
  msg "$(c_cyn '═══════════  warp-rules  ═══════════')"
  local rn_status; rn_status=$(remnanode_status 2>/dev/null)
  [[ -n "$rn_status" ]] && msg "  $(c_yel 'Нода Remnawave:') $(c_grn "$rn_status")"
  na_header_lines
  local i
  for i in "${MENU_ORDER[@]}"; do
    msg "  $i. ${MENU_LABELS[$i]}"
  done
  msg "  0. Выход"
  msg "$(c_cyn '════════════════════════════════════')"
}

main(){
  parse_ipregion_args "$@"
  install_warp_alias 2>/dev/null || true
  [[ -n "${WRULES_INVOKED:-}" ]] && check_for_update
  local choice="${1:-}"

  # если первый аргумент — номер пункта, запустить сразу, без меню
  if [[ "$choice" == "5" ]]; then
    local auto_flag=false a
    for a in "$@"; do [[ "$a" == "--auto" ]] && auto_flag=true; done
    if $auto_flag; then fix_and_update --auto; else fix_and_update; fi
    return $?
  fi
  if [[ -n "$choice" && -n "${MENU_FUNCS[$choice]:-}" ]]; then
    "${MENU_FUNCS[$choice]}"; return $?
  fi

  # иначе показать меню и читать выбор с терминала
  while :; do
    show_menu
    printf '%s' "$(c_yel '[?] Выбор (0-7): ')" >&2
    read -r choice < /dev/tty 2>/dev/null || { msg ""; msg "Нет терминала. Запусти: bash warp-rules.sh 1  (или 2, 3, 4, 5, 6, 7)"; return 1; }
    if [[ "$choice" == "0" ]]; then show_hints; update_motd; msg "Выход."; return 0; fi
    if [[ -n "${MENU_FUNCS[$choice]:-}" ]]; then
      "${MENU_FUNCS[$choice]}"; local mode_rc=$?
      in_list "$choice" "${MENU_EXIT_AFTER[@]}" && return "$mode_rc"
    else
      msg "$(c_red 'Неверный выбор, повтори.')"
    fi
  done
}

# =========================== МОДУЛЬ: ОПТИМИЗАЦИЯ ============================

# выполнить команду с sudo, если не root
opt_run(){ if [[ $EUID -eq 0 ]]; then "$@"; else sudo "$@"; fi; }

# запустить python3 от root, сохраняя окружение
opt_py(){ if [[ $EUID -eq 0 ]]; then python3 -; else sudo -E python3 -; fi; }

# ----------------------------------------------------------------------------
# 2. ЛИМИТЫ RAM ДЛЯ remnanode (docker-compose)
# ----------------------------------------------------------------------------
opt_find_compose(){
  local f d
  for d in /root /opt /srv /home; do
    f=$(find "$d" -maxdepth 4 -name 'docker-compose.y*ml' 2>/dev/null | head -n1)
    [[ -n "$f" ]] && { printf '%s' "$f"; return 0; }
  done
  return 1
}

opt_ensure_ruamel(){
  python3 -c 'from ruamel.yaml import YAML' 2>/dev/null && return 0
  msg "$(c_yel '[*] Устанавливаю ruamel.yaml...')"
  opt_run apt-get install -y python3-ruamel.yaml -qq >/dev/null 2>&1 \
    && python3 -c 'from ruamel.yaml import YAML' 2>/dev/null && return 0
  python3 -m pip install --break-system-packages -q ruamel.yaml 2>/dev/null \
    && python3 -c 'from ruamel.yaml import YAML' 2>/dev/null && return 0
  return 1
}

opt_docker_limits(){
  local cf
  cf=$(opt_find_compose) || {
    msg "$(c_red '[!] docker-compose.yml не найден в стандартных местах.')"
    printf '%s' "$(c_yel '[?] Укажи путь вручную (Enter = пропустить): ')" >&2
    local p; read -r p < /dev/tty 2>/dev/null
    [[ -z "$p" ]] && return 1
    cf="$p"
  }

  msg "$(c_cyn '─── Лимиты RAM для remnanode ───')"
  msg "  Файл: $(c_grn "$cf")"

  local ram_mb
  ram_mb=$(( $(grep MemTotal /proc/meminfo | awk '{print $2}') / 1024 ))
  local lim res heap
  if   [ "$ram_mb" -le 1024 ]; then lim="768m";  res="256m";  heap=256
  elif [ "$ram_mb" -le 2048 ]; then lim="1536m"; res="512m";  heap=512
  else                              lim="3072m"; res="1024m"; heap=1024
  fi
  msg "  RAM: $(c_grn "${ram_mb} MB")  →  limit: $(c_grn "$lim")  reservation: $(c_grn "$res")  heap: $(c_grn "${heap} MB")"
  msg ""

  if ! opt_ensure_ruamel; then
    msg "$(c_red '[!] ruamel.yaml недоступен — файл не изменён.')"
    msg "$(c_yel '[i] Добавь вручную в секцию remnanode:')"
    msg "$(c_cyn "      - NODE_OPTIONS=--max-old-space-size=${heap}")"
    msg "$(c_cyn "    deploy: {resources: {limits: {memory: ${lim}}, reservations: {memory: ${res}}}}")"
    return 1
  fi

  local bak="${cf}.bak.$(date +%Y%m%d_%H%M%S)"
  opt_run cp "$cf" "$bak"
  msg "  Бэкап: $(c_grn "$bak")"

  if MEM_LIMIT="$lim" MEM_RESERV="$res" NODE_HEAP="$heap" COMPOSE_FILE="$cf" \
       opt_py <<'PYEOF'
import os, sys
try:
    from ruamel.yaml import YAML
    from ruamel.yaml.comments import CommentedMap, CommentedSeq
except ImportError:
    sys.exit("no_ruamel")

p       = os.environ["COMPOSE_FILE"]
lim     = os.environ["MEM_LIMIT"]
res     = os.environ["MEM_RESERV"]
new_opt = "NODE_OPTIONS=--max-old-space-size=" + os.environ["NODE_HEAP"]

yml = YAML()
yml.preserve_quotes = True
yml.indent(mapping=2, sequence=4, offset=2)

with open(p) as fh:
    d = yml.load(fh)

if not isinstance(d, dict) or "services" not in d:
    sys.exit("no_services")
svc = d["services"].get("remnanode")
if svc is None:
    sys.exit("no_remnanode")

env = svc.get("environment")
if env is None:
    svc["environment"] = CommentedSeq([new_opt])
elif hasattr(env, "items"):
    env["NODE_OPTIONS"] = new_opt.split("=", 1)[1]
else:
    for i, v in enumerate(env):
        if str(v).startswith("NODE_OPTIONS="):
            env[i] = new_opt
            break
    else:
        env.append(new_opt)

dep = svc.setdefault("deploy", CommentedMap())
rsc = dep.setdefault("resources", CommentedMap())
rsc["limits"]       = CommentedMap({"memory": lim})
rsc["reservations"] = CommentedMap({"memory": res})

with open(p, "w") as fh:
    yml.dump(d, fh)
print("ok")
PYEOF
  then
    msg "$(c_grn '[✓] docker-compose.yml обновлён.')"
  else
    msg "$(c_red '[!] Ошибка патча — откатываю из бэкапа.')"
    opt_run cp "$bak" "$cf"
    return 1
  fi

  if need docker; then
    msg "$(c_yel '[*] Валидирую через docker compose config...')"
    if ! docker compose -f "$cf" config --quiet >/dev/null 2>&1; then
      msg "$(c_red '[!] Валидация не прошла — откатываю из бэкапа.')"
      opt_run cp "$bak" "$cf"
      return 1
    fi
    msg "$(c_grn '[✓] Валидация прошла.')"
  fi

  printf '%s' "$(c_yel '[?] Перезапустить ноду сейчас? (y/N): ')" >&2
  local ans; read -r ans < /dev/tty 2>/dev/null
  if [[ "$ans" =~ ^[yYдД]$ ]]; then
    ( cd "$(dirname "$cf")" && opt_run docker compose down && opt_run docker compose up -d )
    msg "$(c_grn '[✓] Нода перезапущена.')"
  else
    msg "$(c_yel "[i] Перезапусти позже: cd $(dirname "$cf") && docker compose down && docker compose up -d")"
  fi
}

# ============================ ФИКС И ОБНОВЛЕНИЕ ============================
# известные "интерим"-кодовые имена Ubuntu без LTS-статуса —
# при ошибке "does not have a Release file" откатываем на прошлый LTS.
declare -A FAU_LTS_FALLBACK=(
  [noble]="jammy"
  [oracular]="jammy"
  [mantic]="jammy"
  [lunar]="jammy"
  [kinetic]="jammy"
)

# a) репозиторий с неподдерживаемым codename ("does not have a Release file")
fau_fix_release_file(){
  local line="$1" url codename base suffix fallback new_codename file bak

  if [[ "$line" =~ repository\ \'([^\']+)\'\ does\ not\ have\ a\ Release\ file ]]; then
    local repo_desc="${BASH_REMATCH[1]}"
    url="${repo_desc%% *}"
    codename="$(awk '{print $2}' <<<"$repo_desc")"
  else
    msg "$(c_red "[?] Не удалось разобрать источник ошибки Release-файла: $line")"
    return 1
  fi

  file="$(grep -rlF "$url" /etc/apt/sources.list /etc/apt/sources.list.d/*.list 2>/dev/null | head -1)"
  if [[ -z "$file" ]]; then
    msg "$(c_red "[!] Не найден файл-источник для $url — фикс пропущен.")"
    return 1
  fi

  if ! grep -q "$codename" "$file" 2>/dev/null; then
    msg "$(c_grn "[✓] $file уже не содержит '$codename' — похоже, исправлено ранее.")"
    return 0
  fi

  base="${codename%%-*}"; suffix="${codename#"$base"}"
  fallback="${FAU_LTS_FALLBACK[$base]:-}"
  if [[ -z "$fallback" ]]; then
    msg "$(c_yel "[!] Кодовое имя '$codename' неизвестно — безопасная замена невозможна.")"
    msg "$(c_yel "    Предлагаю отключить репозиторий вручную (закомментировать в $file):")"
    msg "$(c_cyn "      sudo sed -i '\\|${url}|s/^deb/#deb/' $file")"
    return 0
  fi
  new_codename="${fallback}${suffix}"

  bak="${file}.bak.$(date +%Y%m%d_%H%M%S)"
  opt_run cp "$file" "$bak"
  if opt_run sed -i "s/\b${codename}\b/${new_codename}/g" "$file"; then
    msg "$(c_grn "[✓] Исправлено: $file — codename '$codename' → '$new_codename' (бэкап: $bak)")"
  else
    msg "$(c_red "[!] Не удалось заменить codename в $file")"
  fi
}

# b) отсутствующий GPG-ключ (NO_PUBKEY) — только показать команду, спросить подтверждение
fau_fix_no_pubkey(){
  local line="$1" auto="$2" keyid
  keyid="$(grep -oE 'NO_PUBKEY [0-9A-Fa-f]+' <<<"$line" | awk '{print $2}')"
  if [[ -z "$keyid" ]]; then
    msg "$(c_red "[?] Не удалось извлечь ID ключа из: $line")"
    return 1
  fi

  msg "$(c_yel "[!] Отсутствует GPG-ключ $keyid — репозиторий не проходит проверку подписи.")"
  msg "$(c_yel '    Добавление чужого ключа — вопрос безопасности, автоматически не выполняется.')"
  msg "$(c_cyn '    Современный способ (keyrings):')"
  msg "$(c_cyn "      curl -fsSL 'https://keyserver.ubuntu.com/pks/lookup?op=get&search=0x${keyid}' | sudo gpg --dearmor -o /etc/apt/keyrings/${keyid}.gpg")"
  msg "$(c_cyn '    Устаревший способ (apt-key, deprecated):')"
  msg "$(c_cyn "      sudo apt-key adv --keyserver keyserver.ubuntu.com --recv-keys ${keyid}")"

  if $auto; then
    msg "$(c_yel "[i] Режим --auto: ключ $keyid не добавлен, требуется ручное вмешательство.")"
    return 0
  fi

  printf '%s' "$(c_yel "[?] Добавить ключ $keyid сейчас через keyserver.ubuntu.com? (y/N): ")" >&2
  local ans; read -r ans < /dev/tty 2>/dev/null
  if [[ "$ans" =~ ^[yYдД]$ ]]; then
    if opt_run gpg --no-default-keyring --keyring "/etc/apt/keyrings/${keyid}.gpg" \
         --keyserver keyserver.ubuntu.com --recv-keys "$keyid" >/dev/null 2>&1; then
      msg "$(c_grn "[✓] Исправлено: ключ $keyid добавлен в /etc/apt/keyrings/${keyid}.gpg")"
    else
      msg "$(c_red "[!] Не удалось добавить ключ $keyid.")"
    fi
  else
    msg "$(c_yel "[i] Ключ $keyid не добавлен — пропущено по решению пользователя.")"
  fi
}

# c) битая строка в sources.list ("Malformed entry N in list file F")
fau_fix_malformed(){
  local line="$1" lineno file bad_line bak
  if [[ "$line" =~ Malformed\ entry\ ([0-9]+)\ in\ list\ file\ ([^\ ]+) ]]; then
    lineno="${BASH_REMATCH[1]}"; file="${BASH_REMATCH[2]}"
  else
    msg "$(c_red "[?] Не удалось разобрать Malformed entry: $line")"
    return 1
  fi

  if [[ ! -f "$file" ]]; then
    msg "$(c_red "[!] Файл $file не найден — фикс пропущен.")"
    return 1
  fi

  bad_line="$(sed -n "${lineno}p" "$file")"
  if [[ "$bad_line" == \#* ]]; then
    msg "$(c_grn "[✓] Строка $lineno в $file уже закомментирована — пропускаю.")"
    return 0
  fi

  msg "$(c_yel "[!] Битая строка $lineno в $file:")"
  msg "$(c_yel "      $bad_line")"

  bak="${file}.bak.$(date +%Y%m%d_%H%M%S)"
  opt_run cp "$file" "$bak"
  if opt_run sed -i "${lineno}s/^/#/" "$file"; then
    msg "$(c_grn "[✓] Исправлено: строка $lineno в $file закомментирована (бэкап: $bak)")"
  else
    msg "$(c_red "[!] Не удалось закомментировать строку $lineno в $file")"
  fi
}

# разбор строк E:/W: из лога apt update и применение фиксов по известным шаблонам
fau_apply_fixes(){
  local log="$1" auto="$2" line
  while IFS= read -r line; do
    case "$line" in
      *"does not have a Release file"*)
        fau_fix_release_file "$line" ;;
      *NO_PUBKEY*)
        fau_fix_no_pubkey "$line" "$auto" ;;
      *"Malformed entry"*)
        fau_fix_malformed "$line" ;;
      *"Could not resolve"*|*"Temporary failure resolving"*|*"Could not connect"*|*"Connection timed out"*)
        msg "$(c_yel "[i] Похоже на сетевую проблему (DNS/сеть): $line")"
        msg "$(c_yel '    Автофикс не применяется — проверь сеть/DNS вручную.')"
        ;;
      *)
        msg "$(c_red '[?] Неизвестная ошибка, автофикс не применён, требуется ручная проверка:')"
        msg "$(c_red "    $line")"
        ;;
    esac
  done < <(grep -E '^(E:|W:)' "$log" | sort -u)
}

# главная функция: диагностика apt update, автофикс известных ошибок, затем upgrade
fix_and_update(){
  local auto=false a
  for a in "$@"; do [[ "$a" == "--auto" ]] && auto=true; done

  msg "$(c_cyn '─── Фикс и обновление ───')"

  local log1 log2
  log1="$(mktemp)"; log2="$(mktemp)"

  msg "$(c_cyn '[*] Проверяю apt update (диагностика, без сырого вывода)...')"
  opt_run apt-get update >"$log1" 2>&1

  if ! grep -qE '^(E:|W:)' "$log1"; then
    msg "$(c_grn '[✓] apt update прошёл без ошибок.')"
    rm -f "$log1" "$log2"
  else
    msg "$(c_yel '[!] Обнаружены проблемы apt update — разбираю и применяю известные фиксы...')"
    fau_apply_fixes "$log1" "$auto"
    rm -f "$log1"

    msg ""
    msg "$(c_cyn '[*] Повторная проверка apt update...')"
    opt_run apt-get update >"$log2" 2>&1

    if grep -qE '^(E:|W:)' "$log2"; then
      msg "$(c_red '[!] После фиксов остались ошибки apt update:')"
      grep -E '^(E:|W:)' "$log2" | while IFS= read -r line; do
        msg "$(c_red "    $line")"
      done
      msg "$(c_red '[!] apt upgrade не запущен — исправь ошибки вручную и повтори.')"
      rm -f "$log2"
      return 1
    fi
    rm -f "$log2"
    msg "$(c_grn '[✓] После фиксов apt update чист.')"
  fi

  msg ""
  msg "$(c_cyn '[*] Запускаю apt upgrade -y...')"
  if opt_run apt-get upgrade -y; then
    msg "$(c_grn '[✓] Система обновлена.')"
  else
    msg "$(c_red '[!] Ошибка при apt upgrade.')"
    return 1
  fi
}

# =========================== МОДУЛЬ: ОПТИМИЗАЦИЯ И ЗАЩИТА НОДЫ =============
# warp-rules сам больше не оптимизирует хост — это обёртка эксплуатации над
# сторонним node-accelerator (github.com/jestivald/node-accelerator, эталон —
# именно апстрим). node-accelerator запускается ОТДЕЛЬНЫМ процессом (download
# install.sh во временный файл + `bash tmp модуль`), а не сорсится функциями:
# у него свой `set -euo pipefail` и IFS, которые здесь ломали бы меню (8.1 ТЗ).

NA_REF="${NA_REF:-v3.9.2}"
NA_REPO_URL="${NA_REPO_URL:-https://raw.githubusercontent.com/jestivald/node-accelerator/$NA_REF}"
NA_REQUIRE_SIG="${NA_REQUIRE_SIG:-1}"
NA_MINISIGN_PUBKEY="${NA_MINISIGN_PUBKEY:-RWQrJghT9nkdBC3ntiEXF29zrS8o429WhObHKq6I7CKoftVDhQBrBscu}"
NA_CONF_DIR=/etc/node-accelerator
NA_STATE_DIR=/var/lib/node-accelerator
WR_HARDEN_ENV=/etc/warp-rules/harden.env
WR_BACKUP_ROOT=/var/backups/warp-rules
# гео-блок — бизнес-решение донора, не хардинг; список стран вынесен в параметр
NA_GEOBLOCK_COUNTRIES_DEFAULT="tw,in,bd,vn,id,ph,ir,pk,th,mm,kh,la,ng,eg,ke,tz,et,br,ve,ec"
NA_MIN_CUSTOM_BLOCKLIST_CIDRS=1000
# коммит shadow-netlab/traffic-guard-lists, проверен вручную перед переносом (раздел 4.2 ТЗ)
NA_SCANLIST_REF="${NA_SCANLIST_REF:-aa4c79a665007bc6df00f53c0622cd9fa8aaef81}"

# ключи node-accelerator, которые warp-rules передаёт через ENV (см. 6.3.4 ТЗ)
NA_UPSTREAM_KEYS=(SSH_PORT TCP_PORTS UDP_PORTS NODE_PORT WHITELIST SAFETY_DELAY \
                  ENABLE_BLOCKLISTS BLOCK_TOR ENABLE_CTGUARD \
                  ENABLE_XANMOD QDISC REMNAWAVE_SWAP_SIZE)
# свои ключи (не из node-accelerator) — тоже хранятся в harden.env
WR_OWN_KEYS=(NA_GEOBLOCK_COUNTRIES REMOVE_LEGACY_FIREWALL)
NA_ENV_KEYS=("${NA_UPSTREAM_KEYS[@]}" "${WR_OWN_KEYS[@]}")

na_require_root(){ [[ $EUID -eq 0 ]] || { msg "$(c_red '[!] Нужен root: перезапусти через sudo (node-accelerator работает только от root).')"; return 1; }; }

# na_get <conf-файл> <KEY> — эффективное значение node-accelerator. Формат
# protect.conf/optimize.conf — не KEY=value, идиома `: "${KEY:=val}"`
# (присваивает, только если KEY ещё не задан) — grep '^KEY=' её не поймёт,
# нужен сорсинг в субшелле с предварительным unset (см. 1.3 ТЗ).
na_get(){
  local f="$1" k="$2"
  [[ -f "$f" ]] || return 0
  # shellcheck disable=SC1090  # путь заведомо динамический (protect.conf/optimize.conf на ноде)
  ( unset "$k"; . "$f" 2>/dev/null; printf '%s' "${!k-}" )
}

# «заявленные владельцем» параметры (то, что мы передаём в ENV при каждом apply) —
# отдельно от protect.conf/optimize.conf, чтобы видеть расхождение (5.3 ТЗ)
# shellcheck disable=SC1090  # путь заведомо динамический (harden.env владельца)
na_load_env(){ [[ -f "$WR_HARDEN_ENV" ]] && . "$WR_HARDEN_ENV" 2>/dev/null; return 0; }

na_save_env(){
  install -d -m 0700 "$(dirname "$WR_HARDEN_ENV")" 2>/dev/null
  local tmp k v; tmp="$(mktemp)"
  {
    printf '# warp-rules — заявленные параметры node-accelerator (%s)\n' "$(date -Is)"
    printf '# фактически применённое: /etc/node-accelerator/{protect,optimize}.conf\n'
    for k in "${NA_ENV_KEYS[@]}"; do
      v="${!k-}"
      [[ -n "$v" ]] && printf '%s=%q\n' "$k" "$v"
    done
  } > "$tmp"
  install -m 0600 "$tmp" "$WR_HARDEN_ENV"
  rm -f "$tmp"
}

# na_set_param KEY VALUE — обновить один ключ в harden.env, не потеряв остальные
na_conf_file_for_key(){
  case "$1" in
    ENABLE_XANMOD|QDISC|REMNAWAVE_SWAP_SIZE) printf '%s' "$NA_CONF_DIR/optimize.conf" ;;
    *) printf '%s' "$NA_CONF_DIR/protect.conf" ;;
  esac
}

# Убрать ключ из protect.conf/optimize.conf насовсем. Нужен для очистки: пустой
# ENV НЕ очищает сохранённое значение — идиома `: "${KEY:=val}"` не отличает
# "пусто" от "не задано", поэтому load_conf снова подставит старое значение.
# Без этого снятие последнего whitelist-IP или закрытие всех портов молча не
# применится (protect.sh отработает "успешно", список останется прежним).
na_conf_unset(){
  local f="$1" k="$2" tmp line prefix
  [[ -f "$f" ]] || return 0
  # shellcheck disable=SC2016  # одинарные кавычки нужны: $/{ должны остаться литералом для printf, не раскрыться в shell
  printf -v prefix ': "${%s:=' "$k"
  tmp="$(mktemp)"
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" == "$prefix"* ]] && continue
    printf '%s\n' "$line"
  done < "$f" > "$tmp"
  install -m 0600 "$tmp" "$f"
  rm -f "$tmp"
}

na_set_param(){
  local key="$1" val="$2"
  na_load_env
  printf -v "$key" '%s' "$val"
  na_save_env
  if [[ -z "$val" ]] && in_list "$key" "${NA_UPSTREAM_KEYS[@]}"; then
    na_conf_unset "$(na_conf_file_for_key "$key")" "$key"
    msg "$(c_yel "[i] $key снят из $(na_conf_file_for_key "$key") — apply применит пустое значение, а не старое.")"
  fi
}

na_installed(){ [[ -d "$NA_CONF_DIR" ]]; }

# nод-accelerator v3.9.2 уже персистит этот маркер сам (optimize.sh, $STATE_DIR/optimize.installed) —
# свой маркер поверх писать не нужно, читаем готовый (см. отчёт: расхождение с 1.3/4.5 ТЗ)
na_reboot_needed(){ grep -q '^reboot_needed=1' "$NA_STATE_DIR/optimize.installed" 2>/dev/null; }

na_safety_armed(){
  systemctl is-active --quiet na-fw-safety.timer 2>/dev/null && return 0
  [[ -f "$NA_STATE_DIR/na-fw-safety.pid" ]] && kill -0 "$(cat "$NA_STATE_DIR/na-fw-safety.pid" 2>/dev/null)" 2>/dev/null
}

na_safety_remaining_s(){
  # systemd-run --on-active создаёт МОНОТОННЫЙ таймер (относительно аптайма,
  # не календаря) — NextElapseUSecRealtime у него всегда n/a, нужен Monotonic
  # + текущий монотонный момент из /proc/uptime.
  local next_us uptime_s now_us diff
  next_us="$(systemctl show na-fw-safety.timer -p NextElapseUSecMonotonic --value 2>/dev/null)"
  [[ "$next_us" =~ ^[0-9]+$ && "$next_us" -gt 0 ]] || return 1
  uptime_s="$(awk '{print $1}' /proc/uptime 2>/dev/null)"
  [[ -n "$uptime_s" ]] || return 1
  now_us="$(awk -v u="$uptime_s" 'BEGIN{printf "%.0f", u*1000000}')"
  diff=$(( next_us - now_us ))
  (( diff > 0 )) && echo $(( diff / 1000000 )) || echo 0
}

# дешёвая шапка статуса для главного меню (6.1 ТЗ) — только если node-accelerator
# вообще применялся; только nft/systemctl/чтение файла, без docker и без sleep
na_header_lines(){
  na_installed || return 0
  local kern qdisc reb fw crowd saf secs
  kern="$(uname -r)"; qdisc="$(sysctl -n net.core.default_qdisc 2>/dev/null)"
  if na_reboot_needed; then reb="$(c_red 'ТРЕБУЕТСЯ РЕБУТ')"; else reb="ребут не требуется"; fi
  msg "  $(c_yel 'Ядро:') $(c_grn "$kern") · qdisc ${qdisc:-?} · $reb"
  nft list table inet na_filter >/dev/null 2>&1 && fw="$(c_grn 'na_filter активен')" || fw="$(c_red 'na_filter отсутствует')"
  systemctl is-active --quiet crowdsec 2>/dev/null && crowd="$(c_grn 'CrowdSec ok')" || crowd="$(c_yel 'CrowdSec —')"
  if na_safety_armed; then
    secs="$(na_safety_remaining_s 2>/dev/null)"
    saf="$(c_red "авто-откат ВЗВЕДЁН${secs:+, осталось ${secs}с}")"
  else
    saf="авто-откат снят"
  fi
  msg "  $(c_yel 'Защита:') $fw · $crowd · $saf"
}

# ── валидация ввода (whitelist/порты уходят в nft-heredoc — мусор нельзя) ──
na_valid_ipcidr(){
  local v="$1"
  [[ -n "$v" ]] || return 1
  # без точки/двоеточия это не IPv4/IPv6 — иначе чистый hex ("abc", "dead") проходил
  # бы как «валидный» через класс символов [0-9a-fA-F:.]
  [[ "$v" == *.* || "$v" == *:* ]] || return 1
  [[ "$v" =~ ^[0-9a-fA-F:.]+(/[0-9]{1,3})?$ ]] || return 1
  if [[ "$v" == *.* && "$v" != *:* ]]; then
    local ip="${v%%/*}" o
    IFS='.' read -ra o <<<"$ip"
    [[ ${#o[@]} -eq 4 ]] || return 1
    local n
    for n in "${o[@]}"; do
      [[ "$n" =~ ^[0-9]{1,3}$ ]] || return 1
      (( 10#$n <= 255 )) || return 1
    done
  fi
  return 0
}

na_validate_whitelist(){
  local list="$1" v
  [[ -n "$list" ]] || return 1
  local -a items; IFS=',' read -ra items <<<"$list"
  for v in "${items[@]}"; do
    v="${v// /}"; [[ -n "$v" ]] || continue
    na_valid_ipcidr "$v" || return 1
  done
  return 0
}

na_validate_ports(){
  local list="$1" v
  [[ -n "$list" ]] || return 1
  local -a items; IFS=',' read -ra items <<<"$list"
  for v in "${items[@]}"; do
    [[ "$v" =~ ^[0-9]{1,5}$ ]] || return 1
    (( 10#$v >= 1 && 10#$v <= 65535 )) || return 1
  done
  return 0
}

# снапшот шире, чем rollback node-accelerator (тот откатывает только своё) —
# фиксирует ЧУЖИЕ правила, которые были до всего (4.4 ТЗ)
na_snapshot(){
  local ts dir; ts="$(date -u +%Y%m%dT%H%M%SZ)"; dir="$WR_BACKUP_ROOT/$ts"
  install -d -m 0700 "$dir"
  nft list ruleset >"$dir/nft.ruleset" 2>/dev/null || true
  iptables-save >"$dir/iptables.rules" 2>/dev/null || true
  ip6tables-save >"$dir/ip6tables.rules" 2>/dev/null || true
  systemctl list-unit-files 'na-*' --no-legend >"$dir/na-units.txt" 2>/dev/null || true
  systemctl status crowdsec crowdsec-firewall-bouncer --no-pager >"$dir/crowdsec-status.txt" 2>&1 || true
  [[ -f "$NA_CONF_DIR/custom-blocklist.txt" ]] && cp -a "$NA_CONF_DIR/custom-blocklist.txt" "$dir/custom-blocklist.txt" 2>/dev/null
  msg "$(c_grn "[✓] Снапшот: $dir")"
}

# apt.conf.d force-confold на время прогона — иначе dpkg виснет на вопросе о
# конфигах в неинтерактивном режиме (4.6 ТЗ); снимается через trap RETURN
NA_APT_CONFOLD_FILE=/etc/apt/apt.conf.d/99-warp-rules-hardening
na_apt_confold_on(){ printf '%s\n' 'Dpkg::Options { "--force-confdef"; "--force-confold"; }' > "$NA_APT_CONFOLD_FILE"; }
na_apt_confold_off(){ rm -f "$NA_APT_CONFOLD_FILE"; }

# NA_REQUIRE_SIG=1 проверяет подписи ВСЕХ модулей node-accelerator (install.sh
# сверяет .minisig на lib/common.sh, optimize.sh, protect.sh, diagnose.sh,
# na-report.sh, rollback.sh) — это штатный механизм апстрима, шире, чем
# SHA256 одного install.sh у донора (5.2 ТЗ). Нужен бинарь minisign.
na_ensure_minisign(){
  [[ "$NA_REQUIRE_SIG" == 1 ]] || return 0
  command -v minisign >/dev/null 2>&1 && return 0
  msg "$(c_yel '[*] Устанавливаю minisign (для проверки подписей node-accelerator)...')"
  apt-get update -qq 2>/dev/null || true
  apt-get install -y -qq minisign >/dev/null 2>&1 && return 0
  msg "$(c_red '[!] Не удалось поставить minisign — проверка подписи невозможна.')"
  msg "$(c_yel '    Поставь пакет вручную либо временно ослабь: NA_REQUIRE_SIG=0.')"
  return 1
}

na_download_install(){
  local dest="$1"
  curl -fsSL --proto '=https' --proto-redir '=https' --connect-timeout 15 --max-time 60 \
    "$NA_REPO_URL/install.sh" -o "$dest" \
    || { msg "$(c_red "[!] Не удалось скачать install.sh из $NA_REPO_URL")"; return 1; }
  chmod 0700 "$dest"
}

# если WHITELIST пуст — спросить IP панели (иначе она рискует остаться без
# admin-доступа к порту ноды при первом же protect); пусто = продолжить на свой риск
na_ensure_whitelist(){
  na_load_env
  local cur="${WHITELIST:-}"
  [[ -z "$cur" ]] && cur="$(na_get "$NA_CONF_DIR/protect.conf" WHITELIST)"
  [[ -n "$cur" ]] && return 0
  msg "$(c_yel '[!] WHITELIST пуст. Без IP панели/мониторинга при первом apply есть риск не достучаться до порта ноды.')"
  printf '%s' "$(c_yel '[?] IP/CIDR панели через запятую (Enter — пропустить на свой риск): ')" >&2
  local ans; read -r ans < /dev/tty 2>/dev/null
  if [[ -n "$ans" ]]; then
    if ! na_validate_whitelist "$ans"; then
      msg "$(c_red '[!] Некорректный формат IP/CIDR — apply отменён.')"
      return 1
    fi
    WHITELIST="$ans"
  else
    msg "$(c_yel '[i] Продолжаю без WHITELIST.')"
  fi
  return 0
}

# ── применить: optimize|protect|all — отдельным процессом (8.1 ТЗ) ──
# 99-zz-bbr-cake.conf / 99-zz-node-limits.conf — конфиги старых модулей
# warp-rules (уже удалённых). Сортируются ПОСЛЕ 99-node-accelerator.conf
# ("n" < "z") и молча перебивают его тюнинг без единого сообщения — снести
# нужно ДО первого apply optimize, иначе конфликт останется (владелец решил:
# сносить сразу, а не отдельным шагом).
na_cleanup_legacy_sysctl(){
  local f found=0
  for f in /etc/sysctl.d/99-zz-bbr-cake.conf /etc/sysctl.d/99-zz-node-limits.conf \
           /etc/modules-load.d/bbr-cake.conf /etc/security/limits.d/99-node.conf; do
    [[ -f "$f" ]] && { rm -f "$f"; found=1; }
  done
  [[ "$found" -eq 1 ]] || return 0
  msg "$(c_grn '[✓] Старые конфиги warp-rules (99-zz-bbr-cake.conf, 99-zz-node-limits.conf) удалены — не будут перебивать тюнинг node-accelerator.')"
  sysctl --system >/dev/null 2>&1 || true
}

na_apply(){
  local mode="$1"
  na_require_root || return 1
  if [[ "$mode" == protect || "$mode" == all ]]; then
    na_ensure_whitelist || return 1
  fi
  na_snapshot
  [[ "$mode" == optimize || "$mode" == all ]] && na_cleanup_legacy_sysctl

  local tmp; tmp="$(mktemp)"
  na_download_install "$tmp" || { rm -f "$tmp"; return 1; }

  na_apt_confold_on
  trap 'na_apt_confold_off' RETURN

  if [[ "$NA_REQUIRE_SIG" == 1 ]]; then
    na_ensure_minisign || { rm -f "$tmp"; return 1; }
  fi

  na_load_env
  local -a envp=(NA_REF="$NA_REF" NA_REPO_URL="$NA_REPO_URL" NA_REQUIRE_SIG="$NA_REQUIRE_SIG" \
                 NA_MINISIGN_PUBKEY="$NA_MINISIGN_PUBKEY" REMNAWAVE_NONINTERACTIVE=1)
  local k v
  for k in "${NA_UPSTREAM_KEYS[@]}"; do
    v="${!k-}"
    [[ -n "$v" ]] && envp+=("$k=$v")
  done

  msg "$(c_cyn "[*] Запускаю node-accelerator $mode ($NA_REF)...")"
  env "${envp[@]}" bash "$tmp" "$mode"
  local rc=$?
  rm -f "$tmp"

  if [[ $rc -eq 0 ]]; then
    na_save_env
    if [[ "$mode" == protect || "$mode" == all ]]; then
      na_configure_crowdsec_remnawave
      na_write_blocklist_updater
      msg ""
      msg "$(c_red "[!] Сейфти-таймер взведён (${SAFETY_DELAY:-900}с). Проверь SSH и HTTPS из ОТДЕЛЬНОЙ сессии, затем пункт «Подтвердить доступ».")"
    fi
    if [[ "$mode" == optimize || "$mode" == all ]] && na_reboot_needed; then
      msg "$(c_yel '[!] Установлено новое ядро XanMod — нужна перезагрузка (reboot), чтобы BBRv3 заработал.')"
    fi
  else
    msg "$(c_red "[!] node-accelerator $mode завершился с ошибкой (код $rc).")"
  fi
  return $rc
}

# ── подтверждение доступа (два действия donor'а: systemd-таймер И nohup+pid,
# у node-accelerator есть оба — снимать нужно оба, см. 4.1 ТЗ) ──
na_confirm(){
  na_require_root || return 1
  if ! na_safety_armed; then
    msg "$(c_grn '[✓] Авто-откат не взведён — подтверждать нечего.')"
    return 0
  fi
  systemctl stop na-fw-safety.service na-fw-safety.timer 2>/dev/null || true
  local pidf="$NA_STATE_DIR/na-fw-safety.pid"
  if [[ -f "$pidf" ]]; then
    kill "$(cat "$pidf" 2>/dev/null)" 2>/dev/null || true
    rm -f "$pidf"
  fi
  if na_safety_armed; then
    msg "$(c_red '[!] Не удалось снять авто-откат — таймер или процесс всё ещё активны.')"
    return 1
  fi
  msg "$(c_grn '[✓] Авто-откат снят. Защита активна на постоянной основе.')"
}

# ── CrowdSec: привязка к remnawave-nginx (без этого CrowdSec работает вхолостую) ──
na_configure_crowdsec_remnawave(){
  local nginx_container
  nginx_container="$(docker ps --format '{{.Names}}' 2>/dev/null | awk '$0 == "remnawave-nginx" {print; exit}')"
  if [[ -z "$nginx_container" ]]; then
    msg "$(c_yel '[i] Контейнер remnawave-nginx не найден — привязка CrowdSec к его логам пропущена.')"
    return 0
  fi
  command -v cscli >/dev/null 2>&1 || { msg "$(c_yel '[i] CrowdSec ещё не установлен — привязка выполнится позже.')"; return 0; }

  install -d -m 0755 /etc/crowdsec/acquis.d /etc/systemd/system/crowdsec.service.d
  local tmp; tmp="$(mktemp)"
  cat > "$tmp" <<EOF
---
source: docker
container_name:
  - $nginx_container
labels:
  type: nginx
EOF
  mv -f "$tmp" /etc/crowdsec/acquis.d/remnawave-nginx-docker.yaml
  # старый инсталлятор мог класть nginx-docker.yaml — снести только при побайтовом совпадении
  if [[ -f /etc/crowdsec/acquis.d/nginx-docker.yaml ]] \
     && cmp -s /etc/crowdsec/acquis.d/remnawave-nginx-docker.yaml /etc/crowdsec/acquis.d/nginx-docker.yaml; then
    rm -f /etc/crowdsec/acquis.d/nginx-docker.yaml
  fi

  tmp="$(mktemp)"
  cat > "$tmp" <<'EOF'
[Service]
Environment=GOGC=20
Environment=GOMAXPROCS=1
EOF
  mv -f "$tmp" /etc/systemd/system/crowdsec.service.d/remnawave-limits.conf

  cscli collections install crowdsecurity/nginx >/dev/null 2>&1
  local scenario
  for scenario in http-wordpress-scan http-magento-scan http-phpmyadmin-scan http-thinkphp-scan; do
    cscli scenarios remove "crowdsecurity/$scenario" >/dev/null 2>&1 || true
  done

  systemctl daemon-reload
  systemctl restart crowdsec.service crowdsec-firewall-bouncer.service 2>/dev/null || true
  msg "$(c_grn "[✓] CrowdSec привязан к логам $nginx_container (GOGC=20/GOMAXPROCS=1, коллекция nginx, шумные web-сценарии сняты).")"
}

# ── блоклист-апдейтер: скан/гео-списки → custom-blocklist.txt (штатная точка
# расширения protect.sh) + systemd-таймер (4.2 ТЗ) ──
na_write_blocklist_updater(){
  na_load_env
  local countries="${NA_GEOBLOCK_COUNTRIES:-$NA_GEOBLOCK_COUNTRIES_DEFAULT}"
  local custom="$NA_CONF_DIR/custom-blocklist.txt"
  local updater=/usr/local/sbin/remnawave-update-scanner-lists
  install -d -m 0750 "$NA_CONF_DIR"

  local tmp; tmp="$(mktemp)"
  cat > "$tmp" <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail
IFS=\$'\n\t'
umask 027

CUSTOM_LIST='$custom'
MIN_CIDRS='$NA_MIN_CUSTOM_BLOCKLIST_CIDRS'
COUNTRIES='$countries'
TG_REF='$NA_SCANLIST_REF'
WORK=\$(mktemp -d /var/tmp/remnawave-blocklist.XXXXXX)
trap 'rm -rf "\$WORK"' EXIT

fetch() { curl --fail --silent --show-error --location --proto '=https' --connect-timeout 15 --max-time 90 --retry 3 --retry-delay 2 "\$1" -o "\$2"; }
fetch "https://raw.githubusercontent.com/shadow-netlab/traffic-guard-lists/\$TG_REF/public/antiscanner.list" "\$WORK/antiscanner.list" || true
fetch "https://raw.githubusercontent.com/shadow-netlab/traffic-guard-lists/\$TG_REF/public/government_networks.list" "\$WORK/government_networks.list" || true
IFS=',' read -ra _countries <<<"\$COUNTRIES"
for country in "\${_countries[@]}"; do
  [[ -n "\$country" ]] || continue
  fetch "https://www.ipdeny.com/ipblocks/data/countries/\${country}.zone" "\$WORK/\${country}.zone" || true
done

python3 - "\$WORK" "\$WORK/custom-blocklist.txt" "\$MIN_CIDRS" <<'PY'
import ipaddress, pathlib, sys
root, output, minimum = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2]), int(sys.argv[3])
nets = []
for path in root.glob('*'):
    if path.name == output.name:
        continue
    for raw in path.read_text(encoding='utf-8', errors='ignore').splitlines():
        value = raw.split('#', 1)[0].strip()
        if not value:
            continue
        try:
            net = ipaddress.ip_network(value, strict=False)
        except ValueError:
            continue
        if net.version == 4:
            nets.append(net)
collapsed = list(ipaddress.collapse_addresses(nets))
if len(collapsed) < minimum:
    raise SystemExit(f'refusing replacement: only {len(collapsed)} IPv4 CIDRs, need {minimum}')
output.write_text(''.join(f'{net}\n' for net in collapsed), encoding='ascii')
PY

test -s "\$WORK/custom-blocklist.txt"
install -m 0644 "\$WORK/custom-blocklist.txt" "\$CUSTOM_LIST.new"
mv -f "\$CUSTOM_LIST.new" "\$CUSTOM_LIST"
if command -v /usr/local/sbin/na-blocklist-update >/dev/null 2>&1; then
  /usr/local/sbin/na-blocklist-update 1
else
  systemctl start na-blocklist.service 2>/dev/null || true
fi
EOF
  install -m 0750 "$tmp" "$updater"
  rm -f "$tmp"

  cat > /etc/systemd/system/remnawave-scanner-update.service <<EOF
[Unit]
Description=Refresh warp-rules scanner/geo block list (last-known-good)
After=network-online.target na-firewall.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$updater
EOF
  cat > /etc/systemd/system/remnawave-scanner-update.timer <<'EOF'
[Unit]
Description=Daily refresh of warp-rules scanner/geo block list

[Timer]
OnCalendar=*-*-* 04:00:00 UTC
Persistent=true
RandomizedDelaySec=20m

[Install]
WantedBy=timers.target
EOF
  systemctl daemon-reload
  systemctl enable --now remnawave-scanner-update.timer >/dev/null 2>&1
  msg "$(c_grn '[✓] Блоклист-апдейтер установлен (таймер remnawave-scanner-update, 04:00 UTC).')"
}

# ── whitelist / порты ──
na_whitelist_add(){
  na_require_root || return 1
  local cur new ip_input
  cur="$(na_get "$NA_CONF_DIR/protect.conf" WHITELIST)"
  if [[ -z "$cur" ]]; then na_load_env; cur="${WHITELIST:-}"; fi
  msg "  Текущий whitelist: ${cur:-(пусто)}"
  printf '%s' "$(c_yel '[?] IP/CIDR добавить (можно несколько через запятую): ')" >&2
  read -r ip_input < /dev/tty 2>/dev/null
  [[ -z "$ip_input" ]] && { msg "$(c_yel 'Отменено.')"; return 0; }
  if ! na_validate_whitelist "$ip_input"; then msg "$(c_red '[!] Некорректный IP/CIDR — отменено.')"; return 1; fi
  # добавляем по одному адресу — проверка «уже в списке» на всей строке разом
  # пропускала бы дубликаты при вводе нескольких адресов через запятую
  new="$cur"
  local -a items; IFS=',' read -ra items <<<"$ip_input"
  local added=0 e
  for e in "${items[@]}"; do
    e="${e// /}"; [[ -n "$e" ]] || continue
    if [[ ",$new," == *",$e,"* ]]; then
      msg "$(c_yel "[i] $e уже в списке.")"
    else
      new="${new:+$new,}$e"; added=1
    fi
  done
  [[ "$added" -eq 1 ]] || { msg "$(c_yel '[i] Нечего добавлять.')"; return 0; }
  na_set_param WHITELIST "$new"
  msg "$(c_cyn '[*] Применяю через protect...')"
  na_apply protect
  msg "$(c_yel '[i] Не забудь «Подтвердить доступ» после проверки SSH/HTTPS.')"
}

na_whitelist_remove(){
  na_require_root || return 1
  local cur new e
  cur="$(na_get "$NA_CONF_DIR/protect.conf" WHITELIST)"
  if [[ -z "$cur" ]]; then na_load_env; cur="${WHITELIST:-}"; fi
  if [[ -z "$cur" ]]; then msg "$(c_yel '[i] Whitelist пуст.')"; return 0; fi
  msg "  Текущий whitelist: $cur"
  printf '%s' "$(c_yel '[?] IP/CIDR убрать: ')" >&2
  local ip; read -r ip < /dev/tty 2>/dev/null
  [[ -z "$ip" ]] && { msg "$(c_yel 'Отменено.')"; return 0; }
  if [[ ",$cur," != *",$ip,"* ]]; then msg "$(c_yel '[i] Такого адреса в списке нет.')"; return 0; fi
  new=""
  local -a items; IFS=',' read -ra items <<<"$cur"
  for e in "${items[@]}"; do [[ "$e" == "$ip" ]] || new="${new:+$new,}$e"; done
  na_set_param WHITELIST "$new"
  na_apply protect
  msg "$(c_yel '[i] Не забудь «Подтвердить доступ» после проверки SSH/HTTPS.')"
}

na_ports_edit(){
  local action="$1" key p
  msg "  1. TCP  2. UDP"
  printf '%s' "$(c_yel '[?] Протокол (1/2): ')" >&2
  read -r p < /dev/tty 2>/dev/null
  case "$p" in 1) key=TCP_PORTS ;; 2) key=UDP_PORTS ;; *) msg "$(c_red 'Отмена.')"; return 1 ;; esac
  local cur; cur="$(na_get "$NA_CONF_DIR/protect.conf" "$key")"
  if [[ -z "$cur" ]]; then na_load_env; cur="${!key:-}"; fi
  msg "  Текущие порты ($key): ${cur:-(пусто)}"
  printf '%s' "$(c_yel "[?] Порт(ы) для действия «$action» (через запятую): ")" >&2
  local ports; read -r ports < /dev/tty 2>/dev/null
  if ! na_validate_ports "$ports"; then msg "$(c_red '[!] Некорректный список портов.')"; return 1; fi
  local new pp
  local -a req; IFS=',' read -ra req <<<"$ports"
  if [[ "$action" == открыть ]]; then
    new="$cur"
    for pp in "${req[@]}"; do [[ ",$new," == *",$pp,"* ]] || new="${new:+$new,}$pp"; done
  else
    new=""
    local -a cur_a; IFS=',' read -ra cur_a <<<"$cur"
    for pp in "${cur_a[@]}"; do
      [[ -n "$pp" ]] || continue
      [[ ",$ports," == *",$pp,"* ]] || new="${new:+$new,}$pp"
    done
  fi
  na_require_root || return 1
  na_set_param "$key" "$new"
  na_apply protect
  msg "$(c_yel '[i] Не забудь «Подтвердить доступ» после проверки SSH/HTTPS.')"
}

# «пожарный» допуск — прямой nft add element, без ре-рана, до перезапуска na-firewall/ребута
na_firewall_emergency_admit(){
  na_installed || { msg "$(c_yel '[i] node-accelerator ещё не применялся.')"; return 1; }
  na_require_root || return 1
  printf '%s' "$(c_yel '[?] IP для пожарного допуска: ')" >&2
  local ip; read -r ip < /dev/tty 2>/dev/null
  na_valid_ipcidr "$ip" || { msg "$(c_red '[!] Некорректный IP/CIDR.')"; return 1; }
  msg "  1. Ко всем портам (whitelist_v4/v6) — стоит выше всех лимитов"
  msg "  2. Только к порту node-agent (na_nodeport_wl_*)"
  printf '%s' "$(c_yel '[?] Куда (1/2): ')" >&2
  local w set; read -r w < /dev/tty 2>/dev/null
  if [[ "$w" == 2 ]]; then set=na_nodeport_wl; else set=whitelist; fi
  [[ "$ip" == *:* ]] && set="${set}_v6" || set="${set}_v4"
  if nft add element inet na_filter "$set" "{ $ip }" 2>/dev/null; then
    msg "$(c_grn "[✓] $ip добавлен в $set (живёт до перезапуска na-firewall/ребута — не персистится).")"
  else
    msg "$(c_red '[!] Не удалось добавить элемент — есть ли живая na_filter?')"
  fi
}

na_report_ip(){
  command -v na-report >/dev/null 2>&1 || { msg "$(c_yel '[i] na-report ещё не установлен.')"; return 1; }
  printf '%s' "$(c_yel '[?] IP (один адрес, без /CIDR-маски): ')" >&2
  local ip; read -r ip < /dev/tty 2>/dev/null
  if [[ "$ip" == */* ]]; then msg "$(c_red '[!] na-report --ip ожидает один адрес, а не CIDR-диапазон.')"; return 1; fi
  na_valid_ipcidr "$ip" || { msg "$(c_red '[!] Некорректный IP.')"; return 1; }
  na-report --ip "$ip"
}

na_menu_whitelist(){
  while :; do
    local wl tcp udp ssh
    wl="$(na_get "$NA_CONF_DIR/protect.conf" WHITELIST)"
    tcp="$(na_get "$NA_CONF_DIR/protect.conf" TCP_PORTS)"
    udp="$(na_get "$NA_CONF_DIR/protect.conf" UDP_PORTS)"
    ssh="$(na_get "$NA_CONF_DIR/protect.conf" SSH_PORT)"
    msg ""
    msg "  Whitelist: ${wl:-(пусто)}"
    msg "  TCP: ${tcp:-?}    UDP: ${udp:-—}    SSH: ${ssh:-авто}"
    msg "  ─────────────────────────────────────"
    msg "  1. Показать кандидатов (na-fw-top-talkers)"
    msg "  2. Добавить IP/CIDR в whitelist"
    msg "  3. Убрать IP/CIDR из whitelist"
    msg "  4. Открыть порт (TCP/UDP)"
    msg "  5. Закрыть порт"
    msg "  6. Пожарный допуск (без ре-рана, до перезапуска)"
    msg "  7. Проверить IP (na-report --ip)"
    msg "  0. Назад"
    printf '%s' "$(c_yel '[?] Выбор (0-7): ')" >&2
    local c; read -r c < /dev/tty 2>/dev/null || return 1
    case "$c" in
      1) if command -v na-fw-top-talkers >/dev/null 2>&1; then na-fw-top-talkers; else msg "$(c_yel '[i] Ещё не установлено.')"; fi ;;
      2) na_whitelist_add ;;
      3) na_whitelist_remove ;;
      4) na_ports_edit открыть ;;
      5) na_ports_edit закрыть ;;
      6) na_firewall_emergency_admit ;;
      7) na_report_ip ;;
      0) return 0 ;;
      *) msg "$(c_red 'Неверный выбор, повтори.')" ;;
    esac
  done
}

na_menu_params(){
  na_load_env
  msg ""
  msg "$(c_cyn '──── Параметры: заявлено (harden.env) → применено (node-accelerator) ────')"
  local k declared actual f
  for k in "${NA_UPSTREAM_KEYS[@]}"; do
    declared="${!k:-—}"
    f="$NA_CONF_DIR/protect.conf"
    case "$k" in ENABLE_XANMOD|QDISC|REMNAWAVE_SWAP_SIZE) f="$NA_CONF_DIR/optimize.conf" ;; esac
    actual="$(na_get "$f" "$k")"; actual="${actual:-—}"
    msg "$(printf '  %-22s %-20s %s' "$k" "$declared" "$actual")"
  done
  for k in "${WR_OWN_KEYS[@]}"; do
    declared="${!k:-—}"
    msg "$(printf '  %-22s %-20s %s' "$k" "$declared" "(своё, не из node-accelerator)")"
  done
  msg ""
  printf '%s' "$(c_yel '[?] Enter — назад, либо KEY=value чтобы задать (применится при следующем apply): ')" >&2
  local line; read -r line < /dev/tty 2>/dev/null
  [[ -z "$line" ]] && return 0
  if [[ "$line" =~ ^([A-Z_]+)=(.*)$ ]]; then
    local kk="${BASH_REMATCH[1]}" vv="${BASH_REMATCH[2]}"
    if in_list "$kk" "${NA_ENV_KEYS[@]}"; then
      na_require_root || return 1
      na_set_param "$kk" "$vv"
      msg "$(c_grn "[✓] $kk=$vv сохранено в $WR_HARDEN_ENV.")"
    else
      msg "$(c_red "[!] Неизвестный ключ: $kk")"
    fi
  else
    msg "$(c_red '[!] Формат: KEY=value')"
  fi
}

na_menu_status(){
  while :; do
    msg ""
    msg "$(c_cyn '──── Статус и диагностика ────')"
    msg "  1. Краткая сводка"
    msg "  2. na-diagnose (полный health-отчёт)"
    msg "  3. na-diagnose --json"
    msg "  4. na-fw-status (баны, блоклисты, CrowdSec)"
    msg "  5. na-report (форензика атак за 24ч)"
    msg "  6. Список снапшотов правил"
    msg "  0. Назад"
    printf '%s' "$(c_yel '[?] Выбор (0-6): ')" >&2
    local c; read -r c < /dev/tty 2>/dev/null || return 1
    case "$c" in
      1) na_header_lines || msg "$(c_yel '[i] node-accelerator ещё не применялся.')" ;;
      2) if command -v na-diagnose >/dev/null 2>&1; then na-diagnose; else msg "$(c_yel '[i] node-accelerator ещё не применялся.')"; fi ;;
      3) if command -v na-diagnose >/dev/null 2>&1; then na-diagnose --json; else msg "$(c_yel '[i] node-accelerator ещё не применялся.')"; fi ;;
      4) if command -v na-fw-status >/dev/null 2>&1; then na-fw-status; else msg "$(c_yel '[i] Ещё не установлено.')"; fi ;;
      5) if command -v na-report >/dev/null 2>&1; then na-report; else msg "$(c_yel '[i] Ещё не установлено.')"; fi ;;
      6) if [[ -d "$WR_BACKUP_ROOT" ]]; then ls -1 "$WR_BACKUP_ROOT" 2>/dev/null | while IFS= read -r l; do msg "  $l"; done
         else msg "$(c_yel '[i] Снапшотов нет.')"; fi ;;
      0) return 0 ;;
      *) msg "$(c_red 'Неверный выбор, повтори.')" ;;
    esac
  done
}

# legacy ufw/iptables — по умолчанию НЕ трогаем (protect.sh намеренно живёт
# рядом с чужими правилами). Флаш только INPUT (не FORWARD — там цепочки
# Docker, донорский `iptables -F` без указания цепочки их вычищал, 5.1 ТЗ).
na_remove_legacy_firewall(){
  na_require_root || return 1
  msg "$(c_yel '[!] Снятие legacy ufw/iptables. По умолчанию мы их не трогаем — убедись, что')"
  msg "$(c_yel '    na_filter уже применена и SSH-доступ подтверждён (пункт «Подтвердить доступ»).')"
  printf '%s' "$(c_yel '[?] Точно продолжить? Наберите YES: ')" >&2
  local ans; read -r ans < /dev/tty 2>/dev/null
  [[ "$ans" == "YES" ]] || { msg "$(c_yel 'Отменено.')"; return 0; }
  na_snapshot
  systemctl disable --now ufw.service 2>/dev/null || true
  apt-get purge -y ufw >/dev/null 2>&1 || true
  systemctl disable --now traffic-guard.service 2>/dev/null || true
  rm -f /usr/local/bin/traffic-guard /etc/systemd/system/traffic-guard.service
  systemctl daemon-reload
  iptables -P INPUT ACCEPT 2>/dev/null || true
  iptables -F INPUT 2>/dev/null || true
  iptables -X SCANNERS-BLOCK 2>/dev/null || true
  command -v netfilter-persistent >/dev/null 2>&1 && netfilter-persistent save || true
  msg "$(c_grn '[✓] Legacy-цепочка INPUT очищена (FORWARD/Docker-цепочки не трогались).')"
  if docker inspect remnanode >/dev/null 2>&1; then
    msg "$(c_cyn '[*] Проверяю исходящую связность из remnanode...')"
    if docker exec remnanode sh -c 'command -v curl >/dev/null 2>&1 && curl -fsS --max-time 5 https://1.1.1.1 >/dev/null' 2>/dev/null; then
      msg "$(c_grn '[✓] Связность из remnanode подтверждена.')"
    else
      msg "$(c_yel '[!] Не удалось подтвердить связность из remnanode автоматически (нет curl в образе или сеть режется) — проверь вручную.')"
    fi
  fi
}

na_menu_maintenance(){
  msg ""
  msg "  1. Обновить блоклисты сейчас"
  msg "  2. Лимиты RAM для remnanode (docker-compose)"
  msg "  3. Убрать legacy-фаервол (ufw/iptables)"
  msg "  0. Назад"
  printf '%s' "$(c_yel '[?] Выбор (0-3): ')" >&2
  local c; read -r c < /dev/tty 2>/dev/null || return 1
  case "$c" in
    1) na_require_root || return 1
       if [[ -x /usr/local/sbin/remnawave-update-scanner-lists ]]; then
         /usr/local/sbin/remnawave-update-scanner-lists && msg "$(c_grn '[✓] Блоклисты обновлены.')"
       else
         msg "$(c_yel '[i] Блоклист-апдейтер ещё не установлен — примени защиту (пункт 1 → 1 или 3).')"
       fi ;;
    2) opt_docker_limits ;;
    3) na_remove_legacy_firewall ;;
    0) return 0 ;;
    *) msg "$(c_red 'Неверный выбор, повтори.')" ;;
  esac
}

na_rollback(){
  local what="$1"
  na_require_root || return 1
  msg "$(c_yel "[!] Откат node-accelerator: $what")"
  printf '%s' "$(c_yel '[?] Точно? (y/N): ')" >&2
  local ans; read -r ans < /dev/tty 2>/dev/null
  [[ "$ans" =~ ^[yYдД]$ ]] || { msg "$(c_yel 'Отменено.')"; return 0; }
  na_snapshot
  local tmp; tmp="$(mktemp)"
  na_download_install "$tmp" || { rm -f "$tmp"; return 1; }
  env NA_REF="$NA_REF" NA_REPO_URL="$NA_REPO_URL" bash "$tmp" rollback "$what"
  local rc=$?
  rm -f "$tmp"
  [[ $rc -eq 0 ]] && msg "$(c_grn "[✓] Откат ($what) выполнен.")"
  return $rc
}

na_menu_rollback(){
  msg ""
  msg "  1. Откатить защиту (protect)"
  msg "  2. Откатить оптимизацию (optimize)"
  msg "  3. Откатить всё"
  msg "  0. Назад"
  printf '%s' "$(c_yel '[?] Выбор (0-3): ')" >&2
  local c; read -r c < /dev/tty 2>/dev/null || return 1
  case "$c" in
    1) na_rollback protect ;;
    2) na_rollback optimize ;;
    3) na_rollback all ;;
    0) return 0 ;;
    *) msg "$(c_red 'Неверный выбор, повтори.')" ;;
  esac
}

na_menu_apply(){
  msg ""
  msg "  1. Полностью (оптимизация + защита)"
  msg "  2. Только оптимизация (ядро, sysctl, память, NIC)"
  msg "  3. Только защита (nftables + CrowdSec + блоклисты)"
  msg "  0. Назад"
  printf '%s' "$(c_yel '[?] Выбор (0-3): ')" >&2
  local c; read -r c < /dev/tty 2>/dev/null || return 1
  case "$c" in
    1) na_apply all ;;
    2) na_apply optimize ;;
    3) na_apply protect ;;
    0) return 0 ;;
    *) msg "$(c_red 'Неверный выбор, повтори.')" ;;
  esac
}

# ---------------------------------------------------------------------------
# ПУНКТ МЕНЮ 4: «Оптимизация и защита ноды»
# ---------------------------------------------------------------------------
mode_na_hardening(){
  na_require_root || return 1
  while :; do
    local kern qdisc swapsz fw crowd bouncer wl tcp udp ssh
    msg ""
    msg "$(c_cyn '──── Оптимизация и защита ноды ────')"
    kern="$(uname -r)"; qdisc="$(sysctl -n net.core.default_qdisc 2>/dev/null)"
    # REMNAWAVE_SWAP_SIZE в optimize.sh — локальная переменная внутри функции
    # настройки свопа, наружу в save_conf не попадает (optimize.conf её не
    # хранит) — читаем реальное состояние системы, а не конфиг
    swapsz="$(swapon --show=NAME,SIZE --noheadings 2>/dev/null | awk '{printf "%s%s", (NR>1?", ":""), $1" "$2}')"
    msg "  Ядро:  $kern · qdisc ${qdisc:-?} · swap ${swapsz:-нет}"
    nft list table inet na_filter >/dev/null 2>&1 && fw="активен" || fw="нет"
    systemctl is-active --quiet crowdsec 2>/dev/null && crowd="ok" || crowd="—"
    systemctl is-active --quiet crowdsec-firewall-bouncer 2>/dev/null && bouncer="ok" || bouncer="—"
    msg "  Сеть:  na_filter $fw · CrowdSec $crowd · bouncer $bouncer"
    wl="$(na_get "$NA_CONF_DIR/protect.conf" WHITELIST)"
    tcp="$(na_get "$NA_CONF_DIR/protect.conf" TCP_PORTS)"
    udp="$(na_get "$NA_CONF_DIR/protect.conf" UDP_PORTS)"
    ssh="$(na_get "$NA_CONF_DIR/protect.conf" SSH_PORT)"
    msg "  Порты: TCP ${tcp:-?} · UDP ${udp:-—} · SSH ${ssh:-авто}"
    if na_safety_armed; then
      local secs; secs="$(na_safety_remaining_s 2>/dev/null)"
      msg "  $(c_red "Авто-откат: ВЗВЕДЁН${secs:+, осталось ${secs}с}")"
    else
      msg "  Авто-откат: не взведён"
    fi
    msg "$(c_cyn '─────────────────────────────────────────────')"
    msg "  1. Применить"
    msg "  2. Подтвердить доступ (confirm)"
    msg "  3. Белый список и порты"
    msg "  4. Параметры"
    msg "  5. Статус и диагностика"
    msg "  6. Обслуживание"
    msg "  7. Откат"
    msg "  0. Назад"
    printf '%s' "$(c_yel '[?] Выбор (0-7): ')" >&2
    local c; read -r c < /dev/tty 2>/dev/null || return 1
    case "$c" in
      1) na_menu_apply ;;
      2) na_confirm ;;
      3) na_menu_whitelist ;;
      4) na_menu_params ;;
      5) na_menu_status ;;
      6) na_menu_maintenance ;;
      7) na_menu_rollback ;;
      0) return 0 ;;
      *) msg "$(c_red 'Неверный выбор, повтори.')" ;;
    esac
  done
}

# =========================== МОДУЛЬ: ОБНОВЛЕНИЕ/ОТКАТ НОДЫ REMNAWAVE =======

# последние 3 тега релизов remnawave/node с GitHub, по одному в строке
rn_github_releases(){
  local json
  json=$(curl -fsSL --max-time 10 "https://api.github.com/repos/remnawave/node/releases?per_page=3" 2>/dev/null) || return 1
  if need jq; then
    printf '%s' "$json" | jq -r '.[].tag_name' 2>/dev/null
  else
    printf '%s' "$json" | grep -o '"tag_name": *"[^"]*"' | sed -E 's/.*"([^"]+)"$/\1/'
  fi
}

mode_remnanode_update(){
  if ! docker inspect remnanode >/dev/null 2>&1; then
    msg "$(c_red '[!] Нода remnanode не найдена.')"
    msg "$(c_yel '[i] Сначала установи её через пункт 3 меню.')"
    return 1
  fi

  msg "$(c_cyn '─── Обновление / откат ноды Remnawave ───')"
  msg "  Текущая версия: $(c_grn "$(remnanode_status)")"
  msg ""

  local -a vers=()
  local v
  while IFS= read -r v; do [[ -n "$v" ]] && vers+=("${v#v}"); done < <(rn_github_releases)
  [[ ${#vers[@]} -eq 0 ]] && msg "$(c_yel '[!] Не удалось получить список релизов с GitHub (сеть/лимит API).')"

  local i=1
  for v in "${vers[@]}"; do msg "  $i. $v"; i=$((i+1)); done
  local manual_idx=$i
  msg "  $manual_idx. Ввести версию вручную"
  msg "  0. Отмена"
  msg ""
  printf '%s' "$(c_yel "[?] Выбор (0-$manual_idx): ")" >&2
  local choice; read -r choice < /dev/tty 2>/dev/null || return 1
  [[ "$choice" == "0" ]] && return 0

  local target
  if [[ "$choice" == "$manual_idx" ]]; then
    printf '%s' "$(c_yel '[?] Версия (например 2.7.0): ')" >&2
    read -r target < /dev/tty 2>/dev/null
    target="${target#v}"
  elif [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice < manual_idx )); then
    target="${vers[$((choice-1))]}"
  else
    msg "$(c_red 'Неверный выбор.')"
    return 1
  fi
  [[ -z "$target" ]] && { msg "$(c_red 'Версия не указана.')"; return 1; }

  local dir
  dir=$(docker inspect remnanode --format '{{index .Config.Labels "com.docker.compose.project.working_dir"}}' 2>/dev/null)
  if [[ -z "$dir" || ! -d "$dir" ]]; then
    msg "$(c_red '[!] Не нашёл рабочую директорию docker-compose ноды.')"
    return 1
  fi
  local cf
  cf=$(find "$dir" -maxdepth 1 -name 'docker-compose.y*ml' 2>/dev/null | head -n1)
  if [[ -z "$cf" ]]; then
    msg "$(c_red "[!] docker-compose.yml не найден в $dir")"
    return 1
  fi

  local bak="${cf}.bak.$(date +%Y%m%d_%H%M%S)"
  opt_run cp "$cf" "$bak"

  # правим только тег образа, остальной файл (env/volumes/порты) не трогаем
  if ! opt_run sed -i -E "s|(remnawave/node):[^[:space:]]+|\1:${target}|" "$cf" \
     || ! grep -q "remnawave/node:${target}" "$cf"; then
    msg "$(c_red '[!] Не удалось изменить docker-compose.yml — откатываю.')"
    opt_run cp "$bak" "$cf"
    return 1
  fi

  if need docker && ! (cd "$dir" && docker compose config --quiet >/dev/null 2>&1); then
    msg "$(c_red '[!] Конфиг стал невалиден — откатываю.')"
    opt_run cp "$bak" "$cf"
    return 1
  fi

  msg "$(c_cyn "[*] Скачиваю remnawave/node:${target}...")"
  local out
  if ! out=$(cd "$dir" && opt_run docker compose pull remnanode 2>&1); then
    msg "$(c_red '[!] Ошибка загрузки образа — откатываю.')"
    msg "$out"
    opt_run cp "$bak" "$cf"
    return 1
  fi

  if ! out=$(cd "$dir" && opt_run docker compose up -d remnanode 2>&1); then
    msg "$(c_red '[!] Ошибка запуска — откатываю и поднимаю прежнюю версию.')"
    msg "$out"
    opt_run cp "$bak" "$cf"
    (cd "$dir" && opt_run docker compose up -d remnanode >/dev/null 2>&1)
    return 1
  fi

  spin_sleep 5 "Проверяю ноду..."
  local new_status; new_status=$(remnanode_status)
  if [[ "$new_status" == "$target"* ]]; then
    msg "$(c_grn "[✓] Установлено: remnanode $new_status")"
  else
    msg "$(c_yel "[!] Нода запущена, но версия отличается от ожидаемой: ${new_status:-нет данных}")"
    msg "$(c_yel "    Бэкап прежнего файла: $bak")"
  fi
}

# =========================== МОДУЛЬ: ОБНОВЛЕНИЕ/ОТКАТ XRAY-CORE ============
# Меняет только бинарник xray внутри контейнера ноды, образ/версию самой
# Node не трогает. Независим от режима 6.

XC_NODE_MIN_COMPAT="2.8.0"     # начиная с этой версии Node...
XC_CORE_MIN_COMPAT="26.6.27"   # ...требуется минимум эта версия Xray-Core

# истина, если версия $1 >= $2 (сравнение через sort -V)
xc_ver_ge(){
  local a="$1" b="$2"
  [[ "$(printf '%s\n%s\n' "$a" "$b" | sort -V | tail -n1)" == "$a" ]]
}

# контейнер ноды — тот же, что использует пункт 6
xc_container(){
  docker inspect remnanode >/dev/null 2>&1 && { printf 'remnanode'; return 0; }
  return 1
}

xc_cur_version(){ docker exec "$1" xray version 2>/dev/null | awk 'NR==1{print $2}'; }

xc_node_tag(){
  local img
  img=$(docker inspect "$1" --format '{{.Config.Image}}' 2>/dev/null) || return 1
  printf '%s' "${img##*:}"
}

xc_arch(){ docker exec "$1" uname -m 2>/dev/null; }

# список тегов релизов Xray-Core (по умолчанию без пре-релизов)
xc_releases(){
  local include_pre="$1" limit="$2" json
  json=$(curl -fsSL --max-time 10 "https://api.github.com/repos/XTLS/Xray-core/releases?per_page=30" 2>/dev/null) || return 1
  need jq || { printf '%s' "$json" | grep -o '"tag_name": *"[^"]*"' | sed -E 's/.*"([^"]+)"$/\1/' | head -n "$limit"; return 0; }
  if [[ "$include_pre" == "true" ]]; then
    printf '%s' "$json" | jq -r '.[].tag_name' 2>/dev/null | head -n "$limit"
  else
    printf '%s' "$json" | jq -r '.[] | select(.prerelease==false) | .tag_name' 2>/dev/null | head -n "$limit"
  fi
}

# имя asset-файла под архитектуру внутри контейнера
xc_asset_name(){
  case "$1" in
    x86_64|amd64)   printf 'Xray-linux-64.zip' ;;
    aarch64|arm64)  printf 'Xray-linux-arm64-v8a.zip' ;;
    armv7l|armhf)   printf 'Xray-linux-arm32-v7a.zip' ;;
    i386|i686)      printf 'Xray-linux-32.zip' ;;
    *) return 1 ;;
  esac
}

# прямая ссылка на asset релиза $1 (тег, с "v") под архитектуру $2
xc_asset_url(){
  local tag="$1" arch="$2" asset json url
  asset=$(xc_asset_name "$arch") || return 1
  json=$(curl -fsSL --max-time 10 "https://api.github.com/repos/XTLS/Xray-core/releases/tags/${tag}" 2>/dev/null) || return 1
  if need jq; then
    url=$(printf '%s' "$json" | jq -r --arg n "$asset" '.assets[] | select(.name==$n) | .browser_download_url' 2>/dev/null)
  else
    url=$(printf '%s' "$json" | grep -o "\"browser_download_url\": *\"[^\"]*${asset}\"" | sed -E 's/.*"([^"]+)"$/\1/')
  fi
  [[ -z "$url" ]] && return 1
  printf '%s' "$url"
}

# список бэкапов бинарника внутри контейнера (полные пути)
xc_backups(){ docker exec "$1" sh -c 'ls -1 /usr/local/bin/xray.bak-* 2>/dev/null'; }

# восстановить конкретный бэкап и перезапустить контейнер
xc_restore(){
  local c="$1" bak="$2"
  msg "$(c_cyn "[*] Восстанавливаю $bak...")"
  if ! docker exec "$c" cp "$bak" /usr/local/bin/xray 2>/dev/null; then
    msg "$(c_red '[!] Не удалось восстановить бэкап.')"
    return 1
  fi
  opt_run docker restart "$c" >/dev/null 2>&1
  spin_sleep 4 "Перезапускаю контейнер..."
  local v; v=$(xc_cur_version "$c")
  if [[ -n "$v" ]]; then
    msg "$(c_grn "[✓] Xray-Core восстановлен: $v")"
    return 0
  fi
  msg "$(c_red '[!] После восстановления версия не определяется.')"
  return 1
}

# подменю: показать бэкапы внутри контейнера, дать откатиться на любой
xc_backups_menu(){
  local c="$1"
  local -a baks=()
  local b
  while IFS= read -r b; do [[ -n "$b" ]] && baks+=("$b"); done < <(xc_backups "$c")

  if [[ ${#baks[@]} -eq 0 ]]; then
    msg "$(c_yel '[!] Бэкапов Xray-Core внутри контейнера не найдено.')"
    return 0
  fi

  msg ""
  msg "$(c_cyn '─── Бэкапы Xray-Core в контейнере ───')"
  local i=1
  for b in "${baks[@]}"; do msg "  $i. ${b##*/}"; i=$((i+1)); done
  msg "  0. Назад"
  msg "$(c_cyn '──────────────────────────────────────')"
  printf '%s' "$(c_yel "[?] Выбор (0-$((i-1))): ")" >&2
  local choice; read -r choice < /dev/tty 2>/dev/null || return 1
  [[ "$choice" == "0" ]] && return 0
  if ! [[ "$choice" =~ ^[0-9]+$ ]] || (( choice < 1 || choice > ${#baks[@]} )); then
    msg "$(c_red 'Неверный выбор.')"
    return 1
  fi
  xc_restore "$c" "${baks[$((choice-1))]}"
}

# выбор версии Xray-Core с GitHub, скачивание, бэкап, установка, проверка
xc_pick_and_install(){
  local c="$1" node_tag="$2" arch="$3"
  local include_pre=false tag=""

  while :; do
    msg ""
    msg "$(c_cyn '[*] Получаю список релизов Xray-Core с GitHub...')"
    local -a vers=()
    local v
    while IFS= read -r v; do [[ -n "$v" ]] && vers+=("$v"); done < <(xc_releases "$include_pre" 8)
    [[ ${#vers[@]} -eq 0 ]] && msg "$(c_yel '[!] Не удалось получить список релизов с GitHub (сеть/лимит API).')"

    msg ""
    local i=1
    for v in "${vers[@]}"; do msg "  $i. $v"; i=$((i+1)); done
    local manual_idx=$i
    msg "  $manual_idx. Ввести версию вручную"
    local toggle_idx=$((manual_idx + 1))
    if $include_pre; then
      msg "  $toggle_idx. Скрыть пре-релизы"
    else
      msg "  $toggle_idx. Показать все версии (включая пре-релизы)"
    fi
    msg "  0. Отмена"
    msg ""
    printf '%s' "$(c_yel "[?] Выбор (0-$toggle_idx): ")" >&2
    local choice; read -r choice < /dev/tty 2>/dev/null || return 1

    [[ "$choice" == "0" ]] && return 0
    if [[ "$choice" == "$toggle_idx" ]]; then
      if $include_pre; then include_pre=false; else include_pre=true; fi
      continue
    fi
    if [[ "$choice" == "$manual_idx" ]]; then
      printf '%s' "$(c_yel '[?] Версия (например v26.6.27 или 26.6.27): ')" >&2
      read -r tag < /dev/tty 2>/dev/null
      [[ -z "$tag" ]] && { msg "$(c_red 'Версия не указана.')"; return 1; }
      [[ "$tag" != v* ]] && tag="v${tag}"
      break
    fi
    if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice < manual_idx )); then
      tag="${vers[$((choice-1))]}"
      break
    fi
    msg "$(c_red 'Неверный выбор, повтори.')"
  done

  local target_ver="${tag#v}"

  # проверка совместимости Node >= 2.8.0 <-> Xray-Core >= 26.6.27
  if [[ -n "$node_tag" ]] && xc_ver_ge "$node_tag" "$XC_NODE_MIN_COMPAT" \
     && ! xc_ver_ge "$target_ver" "$XC_CORE_MIN_COMPAT"; then
    msg ""
    msg "$(c_red '======================================================')"
    msg "$(c_red "[!] Node $node_tag требует Xray-Core >= $XC_CORE_MIN_COMPAT.")"
    msg "$(c_red "    Выбранная версия $target_ver — старше и может быть несовместима.")"
    msg "$(c_red '    Нода может не запуститься или работать нестабильно.')"
    msg "$(c_red '======================================================')"
    printf '%s' "$(c_yel '[?] Введите "да, я понимаю риск" чтобы продолжить: ')" >&2
    local confirm; read -r confirm < /dev/tty 2>/dev/null
    if [[ "$confirm" != "да, я понимаю риск" ]]; then
      msg "$(c_yel '[i] Отменено — версия Xray-Core не изменена.')"
      return 0
    fi
  fi

  local asset_url
  asset_url=$(xc_asset_url "$tag" "$arch") || {
    msg "$(c_red "[!] Не нашёл asset под архитектуру ($arch) в релизе $tag.")"
    return 1
  }

  if ! need unzip; then
    msg "$(c_yel '[*] Устанавливаю unzip...')"
    opt_run apt-get install -y unzip -qq >/dev/null 2>&1
    need unzip || { msg "$(c_red '[!] unzip недоступен и не установился — установи вручную.')"; return 1; }
  fi

  local tmpd; tmpd=$(mktemp -d)
  msg "$(c_cyn "[*] Скачиваю ${asset_url##*/} ($tag)...")"
  if ! curl -fsSL --max-time 90 "$asset_url" -o "$tmpd/xray.zip"; then
    msg "$(c_red '[!] Ошибка загрузки архива.')"
    rm -rf "$tmpd"; return 1
  fi

  unzip -o -q "$tmpd/xray.zip" -d "$tmpd/extracted" >/dev/null 2>&1
  local bin="$tmpd/extracted/xray"
  if [[ ! -f "$bin" ]]; then
    msg "$(c_red '[!] В архиве не найден бинарник xray.')"
    rm -rf "$tmpd"; return 1
  fi
  chmod +x "$bin"

  local cur_ver; cur_ver=$(xc_cur_version "$c")
  local bak="/usr/local/bin/xray.bak-${cur_ver:-unknown}"
  if docker exec "$c" test -f "$bak" 2>/dev/null; then
    msg "$(c_yel "[!] Бэкап $bak уже существует — не перезаписываю.")"
  else
    if docker exec "$c" cp /usr/local/bin/xray "$bak" 2>/dev/null; then
      msg "$(c_grn "[✓] Бэкап текущей версии создан: $bak")"
    else
      msg "$(c_red '[!] Не удалось создать бэкап — прерываю, чтобы не потерять путь отката.')"
      rm -rf "$tmpd"; return 1
    fi
  fi

  msg "$(c_cyn "[*] Устанавливаю Xray-Core $target_ver в контейнер...")"
  if ! docker cp "$bin" "$c":/usr/local/bin/xray; then
    msg "$(c_red '[!] docker cp не удался.')"
    rm -rf "$tmpd"; return 1
  fi
  rm -rf "$tmpd"

  opt_run docker restart "$c" >/dev/null 2>&1
  spin_sleep 4 "Перезапускаю контейнер..."

  local new_ver logs_ok=true
  new_ver=$(xc_cur_version "$c")
  docker logs --tail 30 "$c" 2>&1 | grep -qi 'fatal' && logs_ok=false

  if [[ "$new_ver" == "$target_ver" ]] && $logs_ok; then
    msg "$(c_grn "[✓] Xray-Core обновлён: $new_ver")"
  else
    msg "$(c_yel "[!] Проблема после обновления (версия: ${new_ver:-нет данных}, ожидалась $target_ver).")"
    printf '%s' "$(c_yel "[?] Обнаружена проблема. Откатить на предыдущую версию ($bak)? (y/n): ")" >&2
    local ans; read -r ans < /dev/tty 2>/dev/null
    if [[ "$ans" =~ ^[yYдД]$ ]]; then
      xc_restore "$c" "$bak"
    else
      msg "$(c_yel "[i] Откат не выполнен. Бэкап остаётся: $bak")"
    fi
  fi

  msg ""
  msg "$(c_red '[!] Внимание: при следующем обновлении/пересоздании образа Node')"
  msg "$(c_red '    (пункт 6 этого меню или docker pull) версия Xray-Core будет')"
  msg "$(c_red '    перезаписана той, что зашита в новый образ Node. Если хочешь')"
  msg "$(c_red '    сохранить текущую версию Xray после обновления Node — повтори')"
  msg "$(c_red '    обновление Xray заново после пункта 6.')"
}

mode_xray_update(){
  local c
  c=$(xc_container) || {
    msg "$(c_red '[!] Нода remnanode не найдена.')"
    msg "$(c_yel '[i] Сначала установи её через пункт 3 меню.')"
    return 1
  }

  while :; do
    local cur_xray cur_img arch
    cur_xray=$(xc_cur_version "$c")
    cur_img=$(xc_node_tag "$c")
    arch=$(xc_arch "$c")

    msg ""
    msg "$(c_cyn '─── Обновление / откат Xray-Core (без обновления ноды) ───')"
    msg "  Контейнер:          $(c_grn "$c")"
    msg "  Версия Xray-Core:   $(c_grn "${cur_xray:-неизвестно}")"
    msg "  Версия образа Node: $(c_grn "${cur_img:-неизвестно}")"
    msg "  Архитектура:        $(c_grn "${arch:-неизвестно}")"
    msg ""
    msg "  1. Выбрать версию Xray-Core (обновить/откатить)"
    msg "  2. Показать список бэкапов и откатиться"
    msg "  0. Отмена"
    msg "$(c_cyn '─────────────────────────────────────────────────────────')"
    printf '%s' "$(c_yel '[?] Выбор (0-2): ')" >&2
    local choice; read -r choice < /dev/tty 2>/dev/null || return 1
    case "$choice" in
      1) xc_pick_and_install "$c" "$cur_img" "$arch"; return $? ;;
      2) xc_backups_menu "$c" ;;
      0) return 0 ;;
      *) msg "$(c_red 'Неверный выбор, повтори.')" ;;
    esac
  done
}

main "$@"
