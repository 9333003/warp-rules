#!/usr/bin/env bash
#
# warp-rules.sh — инструмент для серверов Xray/VLESS
#
# Меню:
#   1. Анализ сервера + генерация блока маршрутизации для WARP.
#   2. Предварительная проверка пригодности WARP (до установки, с очисткой).
#   3. Установка инструментов (Remnawave / TrafficGuard / Решала / Multitest).
#   4. Оптимизация (память, docker-лимиты, логи).
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
SCRIPT_VERSION="1.1.0"
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
command -v reshala >/dev/null 2>&1 && \
  printf "${YEL}⚡️ Быстрый запуск Решалы:${RST}             ${GRN}reshala${RST}\n"
command -v rknpidor >/dev/null 2>&1 && \
  printf "${YEL}⚡️ Быстрый запуск TrafficGuard:${RST}       ${LBLU}rknpidor${RST}\n"
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
    local has_remnawave=false has_rwbackup=false has_reshala=false \
          has_trafficguard=false has_multitest=false
    command -v remnawave_reverse >/dev/null 2>&1 && has_remnawave=true
    command -v rw-backup         >/dev/null 2>&1 && has_rwbackup=true
    command -v reshala           >/dev/null 2>&1 && has_reshala=true
    command -v rknpidor          >/dev/null 2>&1 && has_trafficguard=true
    command -v multitest         >/dev/null 2>&1 && has_multitest=true

    local -a KEYS=() LABELS=()
    $has_remnawave    || { KEYS+=("remnawave");    LABELS+=("Remnawave"); }
    $has_rwbackup     || { KEYS+=("rw-backup");    LABELS+=("rw-backup (бэкапы Remnawave)"); }
    $has_reshala      || { KEYS+=("reshala");      LABELS+=("Решала"); }
    $has_trafficguard || { KEYS+=("trafficguard"); LABELS+=("TrafficGuard"); }
    $has_multitest    || { KEYS+=("multitest");    LABELS+=("Multitest"); }

    msg ""
    msg "$(c_cyn '──── Установка инструментов ────')"
    $has_remnawave    && msg "  $(c_grn '[✓]') Remnawave"
    $has_rwbackup     && msg "  $(c_grn '[✓]') rw-backup"
    $has_reshala      && msg "  $(c_grn '[✓]') Решала"
    $has_trafficguard && msg "  $(c_grn '[✓]') TrafficGuard"
    $has_multitest    && msg "  $(c_grn '[✓]') Multitest"

    if [[ ${#KEYS[@]} -gt 0 ]]; then
      local any_inst=false
      $has_remnawave || $has_rwbackup || $has_reshala || $has_trafficguard || $has_multitest \
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
      trafficguard)
        msg "$(c_cyn '[*] Устанавливаю TrafficGuard (первичная настройка системы)...')"
        local _tg_tmp; _tg_tmp=$(mktemp)
        if curl -fsSL https://raw.githubusercontent.com/DonMatteoVPN/TrafficGuard-auto/refs/heads/main/install-trafficguard.sh \
               -o "$_tg_tmp" \
            && sed -i '/trafficguard-manager\.sh[[:space:]]*monitor/d' "$_tg_tmp" \
            && bash "$_tg_tmp"; then
          rm -f "$_tg_tmp"
          if { cat > /usr/local/bin/rknpidor << 'WRAPPER'
#!/usr/bin/env bash
_tg=$(mktemp)
curl -fsSL https://raw.githubusercontent.com/DonMatteoVPN/TrafficGuard-auto/refs/heads/main/install-trafficguard.sh \
  -o "$_tg" 2>/dev/null \
  && sed -i '/trafficguard-manager\.sh[[:space:]]*monitor/d' "$_tg" \
  && bash "$_tg" >/dev/null 2>&1
rm -f "$_tg"
exec /opt/trafficguard-manager.sh monitor
WRAPPER
          } && chmod +x /usr/local/bin/rknpidor; then
            msg "$(c_grn '[✓] TrafficGuard установлен.')"
            update_motd
          else
            msg "$(c_red '[✗] Ошибка создания враппера rknpidor.')"
          fi
        else
          rm -f "$_tg_tmp"
          msg "$(c_red '[✗] Ошибка установки TrafficGuard.')"
        fi
        ;;
      reshala)
        msg "$(c_cyn '[*] Устанавливаю Решалу (первичная настройка)...')"
        if wget -4 -q -O /tmp/install_reshala.sh \
            https://raw.githubusercontent.com/DonMatteoVPN/Reshala-Remnawave-Bedolaga/main/install.sh \
            && RESHALA_NO_AUTOSTART=1 bash /tmp/install_reshala.sh; then
          rm -f /tmp/install_reshala.sh
          if { cat > /usr/local/bin/reshala << 'WRAPPER'
#!/usr/bin/env bash
bash <(curl -fsSL https://raw.githubusercontent.com/DonMatteoVPN/Reshala-Remnawave-Bedolaga/main/install.sh) "$@"
WRAPPER
          } && chmod +x /usr/local/bin/reshala; then
            msg "$(c_grn '[✓] Решала установлена.')"
            update_motd
          else
            msg "$(c_red '[✗] Ошибка создания враппера reshala.')"
          fi
        else
          rm -f /tmp/install_reshala.sh
          msg "$(c_red '[✗] Ошибка установки Решалы.')"
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
  command -v reshala >/dev/null 2>&1 && { any=true
    msg "$(c_yel '⚡️ Быстрый запуск Решалы (настройки):') $(c_grn 'reshala')  («РЕШАЛА»)"; }
  command -v rknpidor >/dev/null 2>&1 && { any=true
    msg "$(c_yel '⚡️ Быстрый запуск TrafficGuard:') $(c_cyn 'rknpidor')"; }
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
show_menu(){
  msg ""
  msg "$(c_cyn '═══════════  warp-rules  ═══════════')"
  local rn_status; rn_status=$(remnanode_status 2>/dev/null)
  [[ -n "$rn_status" ]] && msg "  $(c_yel 'Нода Remnawave:') $(c_grn "$rn_status")"
  msg "  1. Анализ сервера + блок для конфига"
  msg "  2. Проверка пригодности WARP (до установки)"
  msg "  3. Установка инструментов (Remnawave / TrafficGuard / Решала / Multitest)"
  msg "  4. Оптимизация (память, docker-лимиты, логи)"
  msg "  5. Обновление системы + фикс при сбоях"
  msg "  6. Обновление / откат ноды Remnawave"
  msg "  7. Обновление / откат Xray-Core (без обновления ноды)"
  msg "  0. Выход"
  msg "$(c_cyn '════════════════════════════════════')"
}

main(){
  parse_ipregion_args "$@"
  install_warp_alias 2>/dev/null || true
  [[ -n "${WRULES_INVOKED:-}" ]] && check_for_update
  local choice="${1:-}"

  # если первый аргумент 1/2/3 — запустить сразу, без меню
  if [[ "$choice" == "1" ]]; then mode_analyze; return $?; fi
  if [[ "$choice" == "2" ]]; then mode_test_warp; return $?; fi
  if [[ "$choice" == "3" ]]; then mode_install_tools; return $?; fi
  if [[ "$choice" == "4" ]]; then mode_optimization; return $?; fi
  if [[ "$choice" == "5" ]]; then
    local auto_flag=false a
    for a in "$@"; do [[ "$a" == "--auto" ]] && auto_flag=true; done
    if $auto_flag; then fix_and_update --auto; else fix_and_update; fi
    return $?
  fi
  if [[ "$choice" == "6" ]]; then mode_remnanode_update; return $?; fi
  if [[ "$choice" == "7" ]]; then mode_xray_update; return $?; fi

  # иначе показать меню и читать выбор с терминала
  while :; do
    show_menu
    printf '%s' "$(c_yel '[?] Выбор (0-7): ')" >&2
    read -r choice < /dev/tty 2>/dev/null || { msg ""; msg "Нет терминала. Запусти: bash warp-rules.sh 1  (или 2, 3, 4, 5, 6, 7)"; return 1; }
    case "$choice" in
      1) mode_analyze; return $? ;;
      2) mode_test_warp; return $? ;;
      3) mode_install_tools ;;
      4) mode_optimization ;;
      5) fix_and_update ;;
      6) mode_remnanode_update ;;
      7) mode_xray_update ;;
      0) show_hints; update_motd; msg "Выход."; return 0 ;;
      *) msg "$(c_red 'Неверный выбор, повтори.')" ;;
    esac
  done
}

# =========================== МОДУЛЬ: ОПТИМИЗАЦИЯ ============================

# выполнить команду с sudo, если не root
opt_run(){ if [[ $EUID -eq 0 ]]; then "$@"; else sudo "$@"; fi; }

# запустить python3 от root, сохраняя окружение
opt_py(){ if [[ $EUID -eq 0 ]]; then python3 -; else sudo -E python3 -; fi; }

# ----------------------------------------------------------------------------
# 1. ГИБРИДНАЯ ПАМЯТЬ: ZRAM (приоритет 100) + disk swap (приоритет -2)
# ----------------------------------------------------------------------------
opt_hybrid_memory(){
  local ram_mb
  ram_mb=$(( $(grep MemTotal /proc/meminfo | awk '{print $2}') / 1024 ))

  local zram_pct swap_mb
  if   [ "$ram_mb" -le 1024 ]; then zram_pct=60; swap_mb=1024
  elif [ "$ram_mb" -le 2048 ]; then zram_pct=50; swap_mb=1024
  elif [ "$ram_mb" -le 4096 ]; then zram_pct=40; swap_mb=2048
  else                              zram_pct=25; swap_mb=2048
  fi

  msg "$(c_cyn '─── Гибридная память (ZRAM + Swap) ───')"
  msg "  RAM: $(c_grn "${ram_mb} MB")  →  ZRAM: $(c_grn "${zram_pct}%")  +  Swap: $(c_grn "${swap_mb} MB")"
  msg ""

  # --- ZRAM (только если ядро поддерживает модуль) ---
  local zram_ok=0
  if ! modinfo zram >/dev/null 2>&1 && [ ! -e /sys/class/zram-control ]; then
    msg "$(c_yel '[!] Модуль zram недоступен в этом ядре — ZRAM пропущен.')"
    msg "$(c_yel '    Будет настроен только дисковый swap.')"
  else
    if ! dpkg -l zram-tools >/dev/null 2>&1; then
      msg "$(c_yel '[*] Устанавливаю zram-tools...')"
      opt_run apt-get install -y zram-tools >/dev/null 2>&1
    fi
    msg "$(c_yel '[*] Настраиваю ZRAM...')"
    printf 'ALGO=zstd\nPERCENT=%s\nPRIORITY=100\n' "$zram_pct" | opt_run tee /etc/default/zramswap >/dev/null
    opt_run systemctl enable zramswap >/dev/null 2>&1
    opt_run systemctl restart zramswap >/dev/null 2>&1
    if swapon --show 2>/dev/null | grep -q zram; then
      msg "$(c_grn '[✓] ZRAM включён (zstd, приоритет 100).')"
      zram_ok=1
    else
      msg "$(c_red '[!] ZRAM не поднялся (ядро без модуля zram?). Останется только swap.')"
    fi
  fi

  # --- Дисковый swap (страховка, низкий приоритет) ---
  if swapon --show 2>/dev/null | grep -q '/swapfile'; then
    msg "$(c_yel '[*] /swapfile уже есть — выставляю приоритет -2.')"
    opt_run swapoff /swapfile 2>/dev/null || true
    opt_run swapon -p -2 /swapfile 2>/dev/null || true
  else
    msg "$(c_yel "[*] Создаю /swapfile (${swap_mb} MB)...")"
    opt_run fallocate -l "${swap_mb}M" /swapfile 2>/dev/null \
      || opt_run dd if=/dev/zero of=/swapfile bs=1M count="${swap_mb}" status=none
    opt_run chmod 600 /swapfile
    opt_run mkswap /swapfile >/dev/null 2>&1
    opt_run swapon -p -2 /swapfile 2>/dev/null || opt_run swapon /swapfile
  fi

  if ! grep -qE '^/swapfile[[:space:]]' /etc/fstab 2>/dev/null; then
    echo '/swapfile none swap sw,pri=-2 0 0' | opt_run tee -a /etc/fstab >/dev/null
  fi
  msg "$(c_grn '[✓] Swap настроен (приоритет -2).')"

  # --- vm.swappiness: 100 с ZRAM, 10 без ---
  local swappiness
  if [ "${zram_ok}" -eq 1 ]; then swappiness=100; else swappiness=10; fi
  echo "vm.swappiness=${swappiness}" | opt_run tee /etc/sysctl.d/99-swappiness.conf >/dev/null
  opt_run sysctl -w "vm.swappiness=${swappiness}" >/dev/null 2>&1
  msg "$(c_grn "[✓] vm.swappiness=${swappiness}.")"
}

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

# ----------------------------------------------------------------------------
# 3. РОТАЦИЯ ЛОГОВ journald
# ----------------------------------------------------------------------------
opt_log_rotation(){
  msg "$(c_cyn '─── Ротация логов journald ───')"
  local jcfg="/etc/systemd/journald.conf"
  if [[ -f "$jcfg" ]]; then
    opt_run sed -i \
      -e 's/^#\?SystemMaxUse=.*/SystemMaxUse=200M/' \
      -e 's/^#\?RuntimeMaxUse=.*/RuntimeMaxUse=50M/' \
      "$jcfg"
    grep -q '^SystemMaxUse='  "$jcfg" || echo 'SystemMaxUse=200M'  | opt_run tee -a "$jcfg" >/dev/null
    grep -q '^RuntimeMaxUse=' "$jcfg" || echo 'RuntimeMaxUse=50M'  | opt_run tee -a "$jcfg" >/dev/null
    opt_run systemctl restart systemd-journald 2>/dev/null || true
    msg "$(c_grn '[✓] journald: SystemMaxUse=200M, RuntimeMaxUse=50M.')"
  else
    msg "$(c_yel '[!] /etc/systemd/journald.conf не найден — пропускаю.')"
  fi
}

# ----------------------------------------------------------------------------
# МЕНЮ МОДУЛЯ "ОПТИМИЗАЦИЯ"
# ----------------------------------------------------------------------------
mode_optimization(){
  while :; do
    msg ""
    msg "$(c_cyn '══════════  Оптимизация  ══════════')"
    msg "  1. Гибридная память (ZRAM + Swap)"
    msg "  2. Лимиты RAM для remnanode (docker-compose)"
    msg "  3. Ротация логов journald"
    msg "  4. Применить всё сразу"
    msg "  0. Назад"
    msg "$(c_cyn '═══════════════════════════════════')"
    printf '%s' "$(c_yel '[?] Выбор (0-4): ')" >&2
    local choice; read -r choice < /dev/tty 2>/dev/null || return 1
    case "$choice" in
      1) opt_hybrid_memory ;;
      2) opt_docker_limits ;;
      3) opt_log_rotation ;;
      4) opt_hybrid_memory; opt_docker_limits; opt_log_rotation ;;
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
