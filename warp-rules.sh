#!/usr/bin/env bash
#
# warp-rules.sh — инструмент для серверов Xray/VLESS
#
# Меню:
#   1. Анализ сервера + генерация блока маршрутизации для WARP.
#   2. Предварительная проверка пригодности WARP (до установки, с очисткой).
#   3. Установка инструментов (Remnawave / TrafficGuard / Решала / Multitest).
#
# Запуск:
#   bash <(curl -fsSL .../warp-rules.sh)        # покажет меню
#   bash warp-rules.sh 1                          # сразу режим 1
#   bash warp-rules.sh 2                          # сразу режим 2
#   bash warp-rules.sh 3                          # сразу режим 3
#   bash warp-rules.sh 1 -- -t 5                  # аргументы после -- уходят в ipregion

set -uo pipefail

# =========================== НАСТРОЙКИ =====================================
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
MOTD_EOF
  command -v remnawave_reverse >/dev/null 2>&1 && \
    printf 'printf "${YEL}⚡️ Быстрый запуск скрипта EGames:${RST}     ${GRN}remnawave_reverse${RST} (или ${GRN}rr${RST})\\n"\n' \
    >> /etc/update-motd.d/99-remnawave-hint
  command -v rw-backup >/dev/null 2>&1 && \
    printf 'printf "${YEL}⚡️ Быстрый запуск бэкапов Remnawave:${RST}  ${GRN}rw-backup${RST}\\n"\n' \
    >> /etc/update-motd.d/99-remnawave-hint
  command -v reshala >/dev/null 2>&1 && \
    printf 'printf "${YEL}⚡️ Быстрый запуск Решалы:${RST}             ${GRN}reshala${RST}\\n"\n' \
    >> /etc/update-motd.d/99-remnawave-hint
  command -v rknpidor >/dev/null 2>&1 && \
    printf 'printf "${YEL}⚡️ Быстрый запуск TrafficGuard:${RST}       ${LBLU}rknpidor${RST}\\n"\n' \
    >> /etc/update-motd.d/99-remnawave-hint
  command -v multitest >/dev/null 2>&1 && \
    printf 'printf "${YEL}⚡️ Быстрый запуск тестов:${RST}             ${LBLU}multitest${RST}\\n"\n' \
    >> /etc/update-motd.d/99-remnawave-hint
  printf 'printf "${YEL}⚡️ Быстрый запуск WARP Rules:${RST}         ${RED}warp${RST}\\n\\n"\n' \
    >> /etc/update-motd.d/99-remnawave-hint
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

# =========================== АЛИАС warp ====================================
install_warp_alias(){
  local target="/usr/local/bin/warp"
  # Уже установлен нами — пропускаем
  [[ -f "$target" ]] && grep -q 'warp-rules' "$target" 2>/dev/null && return 0
  # Конфликт с другой командой warp — не трогаем
  command -v warp >/dev/null 2>&1 && return 1
  cat > "$target" << 'EOF'
#!/usr/bin/env bash
bash <(curl -fsSL https://raw.githubusercontent.com/9333003/warp-rules/main/warp-rules.sh) "$@"
EOF
  chmod +x "$target"
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
  command -v warp >/dev/null 2>&1 \
    && grep -q 'warp-rules' "$(command -v warp)" 2>/dev/null && { any=true
    msg "$(c_yel '⚡️ Быстрый запуск скрипта WARP Rules:') $(c_red 'warp')"; }
  $any && msg ""
}

# =========================== МЕНЮ =========================================
show_menu(){
  msg ""
  msg "$(c_cyn '═══════════  warp-rules  ═══════════')"
  msg "  1. Анализ сервера + блок для конфига"
  msg "  2. Проверка пригодности WARP (до установки)"
  msg "  3. Установка инструментов (Remnawave / TrafficGuard / Решала / Multitest)"
  msg "  0. Выход"
  msg "$(c_cyn '════════════════════════════════════')"
}

main(){
  parse_ipregion_args "$@"
  install_warp_alias 2>/dev/null || true
  local choice="${1:-}"

  # если первый аргумент 1/2/3 — запустить сразу, без меню
  if [[ "$choice" == "1" ]]; then mode_analyze; return $?; fi
  if [[ "$choice" == "2" ]]; then mode_test_warp; return $?; fi
  if [[ "$choice" == "3" ]]; then mode_install_tools; return $?; fi

  # иначе показать меню и читать выбор с терминала
  while :; do
    show_menu
    printf '%s' "$(c_yel '[?] Выбор (0-3): ')" >&2
    read -r choice < /dev/tty 2>/dev/null || { msg ""; msg "Нет терминала. Запусти: bash warp-rules.sh 1  (или 2, 3)"; return 1; }
    case "$choice" in
      1) mode_analyze; return $? ;;
      2) mode_test_warp; return $? ;;
      3) mode_install_tools ;;
      0) show_hints; update_motd; msg "Выход."; return 0 ;;
      *) msg "$(c_red 'Неверный выбор, повтори.')" ;;
    esac
  done
}

main "$@"
