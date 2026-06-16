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
  local f="/etc/update-motd.d/99-remnawave-hint"
  cat > "$f" << 'MOTD'
#!/bin/sh
YEL='\033[1;33m'
GRN='\033[1;32m'
LBLU='\033[1;34m'
RST='\033[0m'
MOTD
  command -v remnawave_reverse >/dev/null 2>&1 && cat >> "$f" << 'MOTD'
printf "${YEL}⚡️ Быстрый запуск скрипта EGames:\n${RST} ${GRN}remnawave_reverse${RST}  (или ${GRN}rr${RST})\n"
MOTD
  command -v rknpidor >/dev/null 2>&1 && cat >> "$f" << 'MOTD'
printf "${YEL}⚡️ Быстрый запуск TrafficGuard:\n${RST} ${LBLU}rknpidor${RST}\n\n"
MOTD
  command -v reshala >/dev/null 2>&1 && cat >> "$f" << 'MOTD'
printf "${YEL}⚡️ Быстрый запуск Решалы (настройки):\n${RST} ${GRN}reshala${RST}  («РЕШАЛА»)\n"
MOTD
  command -v multitest >/dev/null 2>&1 && cat >> "$f" << 'MOTD'
printf "${YEL}⚡️ Быстрый запуск тестов:\n${RST} ${LBLU}multitest${RST}\n\n"
MOTD
  command -v rw-backup >/dev/null 2>&1 && cat >> "$f" << 'MOTD'
printf "${YEL}⚡️ Быстрый запуск бэкапов Remnawave:\n${RST} ${GRN}rw-backup${RST}\n\n"
MOTD
  chmod +x "$f"
}

# =========================== РЕЖИМ 3: ИНСТРУМЕНТЫ ==========================
mode_install_tools(){
  # Проверяем/ставим whiptail
  local use_whiptail=true
  if ! need whiptail; then
    msg "$(c_cyn '[*] whiptail не найден, устанавливаю...')"
    apt-get install -y whiptail >/dev/null 2>&1
    need whiptail || { msg "$(c_yel '[!] whiptail недоступен — текстовое меню.')"; use_whiptail=false; }
  fi

  # Состояние инструментов
  local has_remnawave=false has_trafficguard=false has_reshala=false \
        has_multitest=false has_rwbackup=false
  command -v remnawave_reverse >/dev/null 2>&1 && has_remnawave=true
  command -v rknpidor          >/dev/null 2>&1 && has_trafficguard=true
  command -v reshala           >/dev/null 2>&1 && has_reshala=true
  command -v multitest         >/dev/null 2>&1 && has_multitest=true
  command -v rw-backup         >/dev/null 2>&1 && has_rwbackup=true

  local -a CHOICES=()

  if $use_whiptail; then
    local lbl_rw="Remnawave (скрипт EGames)"
    local lbl_tg="TrafficGuard"
    local lbl_rs="Решала (настройки)"
    local lbl_mt="Multitest (тесты скорости)"
    $has_remnawave    && lbl_rw+=" (установлен)"
    $has_trafficguard && lbl_tg+=" (установлен)"
    $has_reshala      && lbl_rs+=" (установлен)"
    $has_multitest    && lbl_mt+=" (установлен)"

    local st_rw st_tg st_rs st_mt
    $has_remnawave    && st_rw=ON || st_rw=OFF
    $has_trafficguard && st_tg=ON || st_tg=OFF
    $has_reshala      && st_rs=ON || st_rs=OFF
    $has_multitest    && st_mt=ON || st_mt=OFF

    local -a ITEMS=(
      "remnawave"    "$lbl_rw" "$st_rw"
      "trafficguard" "$lbl_tg" "$st_tg"
      "reshala"      "$lbl_rs" "$st_rs"
      "multitest"    "$lbl_mt" "$st_mt"
    )
    $has_remnawave && ! $has_rwbackup && \
      ITEMS+=("rw-backup" "rw-backup (бэкапы Remnawave) — диагностика" "OFF")

    local num_items=$(( ${#ITEMS[@]} / 3 ))
    local HEIGHT=$(( num_items + 8 ))
    local RESULT
    RESULT="$(whiptail --title "Установка инструментов" \
      --checklist "Выбери инструменты (SPACE — отметить, ENTER — ОК):" \
      "$HEIGHT" 72 "$num_items" \
      "${ITEMS[@]}" 3>&1 1>&2 2>&3)" || return 0

    read -ra CHOICES <<< "$RESULT"
    CHOICES=("${CHOICES[@]//\"/}")
  else
    msg ""
    msg "$(c_cyn '=== Установка инструментов ===')"
    msg "  1. Remnawave$(     $has_remnawave    && echo ' (установлен)' || echo '')"
    msg "  2. TrafficGuard$(  $has_trafficguard && echo ' (установлен)' || echo '')"
    msg "  3. Решала$(        $has_reshala      && echo ' (установлен)' || echo '')"
    msg "  4. Multitest$(     $has_multitest    && echo ' (установлен)' || echo '')"
    $has_remnawave && ! $has_rwbackup && \
      msg "  5. rw-backup (диагностика — устанавливается с Remnawave)"
    msg "  0. Назад"
    printf '%s' "$(c_yel '[?] Номера через пробел (напр. 1 3): ')" >&2
    local input
    read -r input < /dev/tty 2>/dev/null || return 1
    local num
    for num in $input; do
      case "$num" in
        1) CHOICES+=("remnawave") ;;
        2) CHOICES+=("trafficguard") ;;
        3) CHOICES+=("reshala") ;;
        4) CHOICES+=("multitest") ;;
        5) $has_remnawave && ! $has_rwbackup && CHOICES+=("rw-backup") ;;
        0) return 0 ;;
      esac
    done
  fi

  # Установка выбранных инструментов
  local tool
  for tool in "${CHOICES[@]}"; do
    case "$tool" in
      remnawave)
        if $has_remnawave; then
          msg "$(c_yel '[!] Remnawave уже установлен — пропускаю.')"
        else
          msg "$(c_cyn '[*] Устанавливаю Remnawave...')"
          if bash <(curl -Ls https://raw.githubusercontent.com/eGamesAPI/remnawave-reverse-proxy/refs/heads/main/install_remnawave.sh); then
            msg "$(c_grn '[✓] Remnawave установлен.')"
            update_motd
          else
            msg "$(c_red '[✗] Ошибка установки Remnawave.')"
          fi
        fi
        ;;
      trafficguard)
        if $has_trafficguard; then
          msg "$(c_yel '[!] TrafficGuard уже установлен — пропускаю.')"
        else
          msg "$(c_cyn '[*] Устанавливаю TrafficGuard...')"
          if curl -fsSL https://raw.githubusercontent.com/DonMatteoVPN/TrafficGuard-auto/refs/heads/main/install-trafficguard.sh | sudo bash; then
            msg "$(c_grn '[✓] TrafficGuard установлен.')"
            update_motd
          else
            msg "$(c_red '[✗] Ошибка установки TrafficGuard.')"
          fi
        fi
        ;;
      reshala)
        if $has_reshala; then
          msg "$(c_yel '[!] Решала уже установлена — пропускаю.')"
        else
          msg "$(c_cyn '[*] Устанавливаю Решалу...')"
          if wget -4 -O /tmp/install_reshala.sh \
              https://raw.githubusercontent.com/DonMatteoVPN/Reshala-Remnawave-Bedolaga/main/install.sh \
              && bash /tmp/install_reshala.sh; then
            msg "$(c_grn '[✓] Решала установлена.')"
            update_motd
          else
            msg "$(c_red '[✗] Ошибка установки Решалы.')"
          fi
        fi
        ;;
      multitest)
        if $has_multitest; then
          msg "$(c_yel '[!] Multitest уже установлен — пропускаю.')"
        else
          msg "$(c_cyn '[*] Устанавливаю Multitest...')"
          if curl -sL https://raw.githubusercontent.com/saveksme/multitest/master/multitest.sh \
              -o /usr/local/bin/multitest && chmod +x /usr/local/bin/multitest; then
            msg "$(c_grn '[✓] Multitest установлен.')"
            update_motd
          else
            msg "$(c_red '[✗] Ошибка установки Multitest.')"
          fi
        fi
        ;;
      rw-backup)
        msg "$(c_yel '[!] rw-backup устанавливается вместе с Remnawave.')"
        msg "$(c_yel '    Переустанови Remnawave (пункт 1) для диагностики.')"
        ;;
    esac
  done
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
      3) mode_install_tools; return $? ;;
      0) msg "Выход."; return 0 ;;
      *) msg "$(c_red 'Неверный выбор, повтори.')" ;;
    esac
  done
}

main "$@"
