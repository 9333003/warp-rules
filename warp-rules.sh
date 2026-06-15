#!/usr/bin/env bash
#
# warp-rules.sh — обёртка над ipregion.sh
#
# Что делает:
#   1. Запускает ipregion.sh с выводом в JSON (-j).
#   2. Определяет "страну сервера" (по GeoIP-сервисам, primary-группа).
#   3. Проходит по сервисам и решает, какие "сломаны":
#        - определяются как RU (а сервер не RU), ИЛИ
#        - имеют явный флаг недоступности (Gemini Supported: No).
#   4. Для каждого сломанного сервиса берёт его домены из таблицы соответствия
#      и печатает готовый JSON-блок "rules" для заворачивания в WARP.
#
# YouTube НЕ трогаем никогда — он пропускается всегда (как ты просил).
#
# Использование:
#   bash warp-rules.sh                 # обычный запуск (локальный IP сервера)
#   bash warp-rules.sh -- -p 127.0.0.1:1080   # всё после -- уходит в ipregion (напр. прокси)
#
# Требует: jq, curl (их ipregion и так ставит).

set -euo pipefail

# ---- настройки -------------------------------------------------------------

WARP_TAG="warp-out"          # тег outbound, в который заворачиваем сломанное
IPREGION_URL="https://raw.githubusercontent.com/vernette/ipregion/master/ipregion.sh"
IPREGION_LOCAL="./ipregion.sh"   # если лежит рядом — используем его, иначе качаем

# Какой GeoIP-сервис из primary считать "истиной" о стране сервера.
# Берём первый из этого списка, у которого есть валидный ответ.
SERVER_COUNTRY_SOURCES=("maxmind.com" "ipinfo.io" "cloudflare.com" "ipapi.co")

# Сервисы, которые НИКОГДА не трогаем (пропускаем в любом случае).
SKIP_SERVICES=("YouTube" "YouTube Premium" "YouTube CDN")

# Таблица соответствия: имя сервиса в ipregion -> домены/geosite для Xray.
# Домены через запятую. Добавляй/правь под себя.
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

# ---- получение JSON от ipregion --------------------------------------------

ipregion_args=()
# всё, что после "--", передаём в ipregion как есть
if [[ "${1:-}" == "--" ]]; then
  shift
  ipregion_args=("$@")
fi

run_ipregion() {
  if [[ -f "$IPREGION_LOCAL" ]]; then
    bash "$IPREGION_LOCAL" -j "${ipregion_args[@]}"
  else
    bash <(curl -fsSL "$IPREGION_URL") -j "${ipregion_args[@]}"
  fi
}

echo "[*] Запускаю ipregion (это займёт ~10-30 сек)..." >&2
JSON="$(run_ipregion)"

if ! echo "$JSON" | jq -e . >/dev/null 2>&1; then
  echo "[!] ipregion вернул не-JSON. Прерываю." >&2
  echo "$JSON" >&2
  exit 1
fi

# ---- определяем страну сервера ---------------------------------------------

SERVER_COUNTRY=""
for src in "${SERVER_COUNTRY_SOURCES[@]}"; do
  val="$(echo "$JSON" | jq -r --arg s "$src" '
    (.results.primary // [])[] | select(.service==$s) | .ipv4 // empty')"
  if [[ -n "$val" && "$val" != "null" && "$val" != "N/A" ]]; then
    SERVER_COUNTRY="$val"
    break
  fi
done

if [[ -z "$SERVER_COUNTRY" ]]; then
  echo "[!] Не смог определить страну сервера из primary-группы." >&2
  exit 1
fi

echo "[*] Страна сервера определена как: $SERVER_COUNTRY" >&2

# ---- решаем, что сломано ----------------------------------------------------

# Собираем все custom-сервисы как "service<TAB>ipv4"
mapfile -t ROWS < <(echo "$JSON" | jq -r '
  (.results.custom // [])[] | "\(.service)\t\(.ipv4 // "")"')

is_skipped() {
  local name="$1"
  for s in "${SKIP_SERVICES[@]}"; do
    [[ "$s" == "$name" ]] && return 0
  done
  return 1
}

# Уникальный набор доменов сломанных сервисов
declare -A BROKEN_DOMAINS=()
BROKEN_REPORT=()

for row in "${ROWS[@]}"; do
  name="${row%%$'\t'*}"
  value="${row#*$'\t'}"

  # пропускаем YouTube и всё из SKIP
  if is_skipped "$name"; then
    continue
  fi

  # есть ли у нас домены для этого сервиса? если нет — пропускаем
  domains="${SERVICE_DOMAINS[$name]:-}"
  [[ -z "$domains" ]] && continue

  broken=false
  reason=""

  # Критерий 1: явный флаг недоступности (Gemini Supported: No и т.п.)
  if [[ "$value" == "No" ]]; then
    broken=true
    reason="недоступен (No)"
  # Критерий 2: определяется как RU, а сервер не RU
  elif [[ "$value" == "RU" && "$SERVER_COUNTRY" != "RU" ]]; then
    broken=true
    reason="определяется как RU"
  fi

  if $broken; then
    BROKEN_REPORT+=("$name — $reason")
    IFS=',' read -ra doms <<<"$domains"
    for d in "${doms[@]}"; do
      [[ -n "$d" ]] && BROKEN_DOMAINS["$d"]=1
    done
  fi
done

# ---- вывод -----------------------------------------------------------------

if [[ ${#BROKEN_DOMAINS[@]} -eq 0 ]]; then
  echo "" >&2
  echo "[OK] Сломанных сервисов не найдено — ничего заворачивать в WARP не нужно." >&2
  exit 0
fi

echo "" >&2
echo "[!] Сломанные сервисы (поедут через '$WARP_TAG'):" >&2
for r in "${BROKEN_REPORT[@]}"; do
  echo "      - $r" >&2
done
echo "" >&2
echo "[*] Готовый блок для секции routing.rules (вставь ВЫШЕ дефолтного маршрута):" >&2
echo "" >&2

# сортируем домены для стабильного вывода
mapfile -t SORTED < <(printf '%s\n' "${!BROKEN_DOMAINS[@]}" | sort)

# собираем JSON-массив доменов через jq и оборачиваем в правило
printf '%s\n' "${SORTED[@]}" | jq -R . | jq -s \
  --arg tag "$WARP_TAG" '{
    type: "field",
    domain: .,
    outboundTag: $tag
  }'
