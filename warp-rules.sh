#!/usr/bin/env bash
#
# warp-rules.sh — анализатор гео сервера и WARP-выхода для Xray
#
# Логика (компромисс):
#   1. ipregion.sh -j -> страна сервера по КОНСЕНСУСУ (большинство голосов GeoIP).
#   2. Ищет "сломанные" сервисы (определяются как RU, либо флаг No, напр. Gemini No).
#      YouTube и YouTube Premium — пропускаются ВСЕГДА (для них RU это плюс).
#   3. Проверяет WARP-выход (cdn-cgi/trace через WG-интерфейс).
#   4. Вердикт:
#        - сервер не-RU, сломанное чинится через WARP   -> выдаём блок;
#        - сервер RU, но WARP даёт не-RU                -> всё равно чиним, выдаём блок;
#        - сервер RU и WARP тоже RU/отсутствует         -> "работа невозможна".
#   5. Печатает готовый JSON-блок доменов для WARP.
#
# Использование:
#   bash warp-rules.sh
#   bash warp-rules.sh -- -p 127.0.0.1:1080   # всё после -- уходит в ipregion

set -uo pipefail

# =========================== НАСТРОЙКИ =====================================
WARP_TAG="warp-out"
IPREGION_URL="https://ipregion.vrnt.xyz"
IPREGION_LOCAL="./ipregion.sh"
IPREGION_TIMEOUT=90        # макс. секунд на прогон ipregion (защита от зависаний типа ipapi.co)
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

# =========================== АРГУМЕНТЫ =====================================
ipregion_args=()
if [[ "${1:-}" == "--" ]]; then shift; ipregion_args=("$@"); fi

run_ipregion(){
  local runner
  if [[ -f "$IPREGION_LOCAL" ]]; then
    timeout "$IPREGION_TIMEOUT" bash "$IPREGION_LOCAL" -j "${ipregion_args[@]}"
  else
    timeout "$IPREGION_TIMEOUT" bash <(curl -fsSL "$IPREGION_URL") -j "${ipregion_args[@]}"
  fi
}

if ! need curl; then msg "$(c_red '[!] curl не установлен')"; exit 1; fi

# =========================== ШАГ 1: СЕРВЕР =================================
msg "$(c_cyn '[*] Проверяю сервер через ipregion (~10-30 сек)...')"
JSON="$(run_ipregion)"; rc=$?
if [[ $rc -eq 124 ]]; then
  msg "$(c_red "[!] ipregion завис и был прерван по таймауту (${IPREGION_TIMEOUT}с).")"
  msg "$(c_red '    Часть GeoIP-сервисов не отвечает. Попробуй позже или передай -t:')"
  msg "$(c_red '    bash warp-rules.sh -- -t 5')"
  exit 1
fi

if ! need jq; then msg "$(c_red '[!] jq не найден. Установи: apt install -y jq')"; exit 1; fi
if ! jq -e . >/dev/null 2>&1 <<<"$JSON"; then
  msg "$(c_red '[!] ipregion вернул не-JSON:')"; msg "$JSON"; exit 1
fi

SERVER_COUNTRY="$(jq -r '(.results.primary // [])[] | .ipv4 // empty' <<<"$JSON" \
  | grep -oE '[A-Z]{2}' | sort | uniq -c | sort -rn | head -1 | awk '{print $2}')"
VOTES="$(jq -r '(.results.primary // [])[] | .ipv4 // empty' <<<"$JSON" \
  | grep -oE '[A-Z]{2}' | sort | uniq -c | sort -rn | awk '{printf "%s×%s ", $2, $1}')"

if [[ -z "$SERVER_COUNTRY" ]]; then
  msg "$(c_red '[!] Не смог определить страну сервера.')"; exit 1
fi

msg ""
msg "$(c_cyn '[*] Страна сервера (консенсус):') $(c_grn "$SERVER_COUNTRY")  $(c_yel "[голоса: $VOTES]")"
SERVER_IS_RU=false
[[ "$SERVER_COUNTRY" == "RU" ]] && SERVER_IS_RU=true
if $SERVER_IS_RU; then
  msg "$(c_yel '    Сервер сам определяется как RU — проверю, спасает ли WARP.')"
fi

# =========================== ШАГ 2: ЧТО СЛОМАНО ===========================
mapfile -t ROWS < <(jq -r '(.results.custom // [])[] | "\(.service)\t\(.ipv4 // "")"' <<<"$JSON")
declare -A BROKEN_DOMAINS=()
BROKEN_REPORT=()

for row in "${ROWS[@]}"; do
  name="${row%%$'\t'*}"; value="${row#*$'\t'}"
  in_list "$name" "${SKIP_SERVICES[@]}" && continue
  domains="${SERVICE_DOMAINS[$name]:-}"; [[ -z "$domains" ]] && continue
  broken=false; reason=""
  if [[ "$value" == "No" ]]; then broken=true; reason="недоступен (No)"
  elif [[ "$value" == "RU" ]]; then broken=true; reason="определяется как RU"; fi
  if $broken; then
    BROKEN_REPORT+=("$name — $reason")
    IFS=',' read -ra doms <<<"$domains"
    for d in "${doms[@]}"; do [[ -n "$d" ]] && BROKEN_DOMAINS["$d"]=1; done
  fi
done

# Если сервер не-RU и ничего не сломано — WARP не нужен
if ! $SERVER_IS_RU && [[ ${#BROKEN_DOMAINS[@]} -eq 0 ]]; then
  msg ""
  msg "$(c_grn '[OK] Сервер не RU и сломанных сервисов нет — WARP не нужен.')"; exit 0
fi

if [[ ${#BROKEN_DOMAINS[@]} -gt 0 ]]; then
  msg ""
  msg "$(c_yel '[!] Сломанные сервисы:')"
  for r in "${BROKEN_REPORT[@]}"; do msg "      - $r"; done
fi

# =========================== ШАГ 3: WARP ==================================
WARP_IF=""
if need wg; then
  WARP_IF="$(wg show interfaces 2>/dev/null | tr ' ' '\n' | grep -v '^$' | head -1)"
fi

WARP_OK="unknown"; WARP_LOC=""
if [[ -z "$WARP_IF" ]]; then
  msg ""
  msg "$(c_yel '[!] WARP-интерфейс не найден (WARP не установлен/не поднят).')"
else
  msg ""
  msg "$(c_cyn '[*] Найден WARP-интерфейс: ')$(c_grn "$WARP_IF")$(c_cyn '. Проверяю туннель...')"

  # --- проверка handshake: туннель вообще установил связь с Cloudflare? ---
  WG_DUMP="$(wg show "$WARP_IF" 2>/dev/null)"
  HAS_HANDSHAKE=false
  grep -q 'latest handshake' <<<"$WG_DUMP" && HAS_HANDSHAKE=true
  # received байты (0 B = ответа от Cloudflare нет)
  RX="$(grep -oE 'transfer: [0-9.]+ [KMGT]?i?B received' <<<"$WG_DUMP" | grep -oE '^transfer: [0-9.]+ [KMGT]?i?B' | grep -oE '[0-9.]+ [KMGT]?i?B')"
  RX_ZERO=false
  [[ "$RX" == "0 B" || -z "$RX" ]] && ! $HAS_HANDSHAKE && RX_ZERO=true

  if ! $HAS_HANDSHAKE && $RX_ZERO; then
    msg "$(c_red '[!] WARP-туннель НЕ поднялся: нет handshake, 0 B получено от Cloudflare.')"
    msg "$(c_red '    Трафик до Cloudflare блокируется (типично для RU-серверов).')"
    msg "$(c_red '    Попробуй сменить endpoint/порт в конфиге WARP, либо смени сервер.')"
    WARP_OK="dead"
  else
    msg "$(c_cyn '    Туннель живой (handshake есть). Проверяю выход...')"
    TRACE="$(curl --interface "$WARP_IF" -s --max-time 12 https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null)"
    WARP_LOC="$(grep -oE '^loc=[A-Z]{2}' <<<"$TRACE" | cut -d= -f2)"
    WARP_COLO="$(grep -oE '^colo=[A-Z]{3}' <<<"$TRACE" | cut -d= -f2)"
    WARP_IP="$(grep -oE '^ip=[0-9a-fA-F:.]+' <<<"$TRACE" | cut -d= -f2)"
    if [[ -z "$WARP_LOC" ]]; then
      msg "$(c_red '[!] Туннель поднят, но выход не отвечает (нет ответа на trace).')"
    else
      msg "$(c_cyn '    WARP выходит как:') $(c_grn "$WARP_LOC")  $(c_yel "(дата-центр: ${WARP_COLO:-?}, IP: ${WARP_IP:-?})")"
      if in_list "$WARP_LOC" "${BAD_COUNTRIES[@]}"; then
        WARP_OK="bad"
      else
        WARP_OK="good"
      fi
    fi
  fi
fi

# =========================== ШАГ 4: ВЕРДИКТ ===============================
# Сервер RU: спасение только если WARP даёт не-RU
if $SERVER_IS_RU; then
  if [[ "$WARP_OK" == "good" ]]; then
    msg ""
    msg "$(c_grn "[OK] Сервер RU, но WARP выходит как $WARP_LOC — спасаемо через WARP.")"
  else
    msg ""
    msg "$(c_red '======================================================')"
    if [[ "$WARP_OK" == "dead" ]]; then
      msg "$(c_red '[!] Сервер РОССИЯ, и WARP-туннель не поднимается')"
      msg "$(c_red '    (нет связи с Cloudflare — трафик блокируется).')"
    else
      msg "$(c_red '[!] Сервер определяется как РОССИЯ, и WARP не спасает')"
      msg "$(c_red "    (WARP: ${WARP_LOC:-нет/недоступен}).")"
    fi
    msg "$(c_red '    Работа невозможна. Сервер для задачи не подходит.')"
    msg "$(c_red '======================================================')"
    exit 2
  fi
fi

# Сервер не-RU, но WARP вышел в плохую страну — предупреждаем
if [[ "$WARP_OK" == "bad" ]]; then
  msg ""
  msg "$(c_red "[!] WARP выходит в нерабочую страну ($WARP_LOC) — чинить через него бесполезно.")"
  msg "$(c_red '    Нужен другой выход. Блок ниже работать не будет.')"
  exit 3
fi

# WARP-туннель мёртв (нет handshake) — блок не заработает
if [[ "$WARP_OK" == "dead" ]]; then
  msg ""
  msg "$(c_red '[!] WARP-туннель не работает (нет связи с Cloudflare).')"
  msg "$(c_red '    Сломанные сервисы через него не починятся.')"
  msg "$(c_red '    Подними WARP (смени endpoint/порт) и перезапусти скрипт.')"
  exit 3
fi

# Дошли сюда — есть что чинить и (WARP good, либо WARP unknown но сервер не-RU)
if [[ ${#BROKEN_DOMAINS[@]} -eq 0 ]]; then
  msg ""
  msg "$(c_grn '[OK] Чинить нечего.')"; exit 0
fi

msg ""
if [[ "$WARP_OK" == "good" ]]; then
  msg "$(c_cyn '[*] Готовый блок для routing.rules (вставь ВЫШЕ дефолтного маршрута):')"
else
  msg "$(c_yel '[*] Предварительный блок (WARP не подтверждён — проверь страну WARP сам!):')"
fi
msg ""

mapfile -t SORTED < <(printf '%s\n' "${!BROKEN_DOMAINS[@]}" | sort)
printf '%s\n' "${SORTED[@]}" | jq -R . | jq -s --arg tag "$WARP_TAG" '{type:"field", domain:., outboundTag:$tag}'
