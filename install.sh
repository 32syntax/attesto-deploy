#!/usr/bin/env bash
# Attest0 — установка на чистый сервер (Ubuntu/Debian).
# Запускать от root (или через sudo): curl -fsSL <URL>/install.sh | sudo bash
set -euo pipefail

REPO_RAW_BASE="${REPO_RAW_BASE:-https://raw.githubusercontent.com/32syntax/attesto-deploy/main}"
INSTALL_DIR="${INSTALL_DIR:-/opt/attest0}"
GHCR_OWNER_DEFAULT="32syntax"

log()  { echo -e "\033[1;32m[install]\033[0m $*"; }
warn() { echo -e "\033[1;33m[install]\033[0m $*"; }
die()  { echo -e "\033[1;31m[install]\033[0m $*" >&2; exit 1; }

# Читает .env построчно как KEY=VALUE и экспортирует — не "source",
# который выполняет файл как bash-код: значение с пробелом без кавычек
# (например, INVOICE_PAYEE_NAME=ООО Ромашка) сломает выполнение, а
# спецсимволы в значении выполнились бы как код.
load_env() {
  local key value
  while IFS='=' read -r key value; do
    [[ -z "${key}" || "${key}" == \#* ]] && continue
    export "${key}=${value}"
  done < "$1"
}

[[ $EUID -eq 0 ]] || die "Запустите скрипт от root (sudo bash install.sh)."

log "Шаг 1/6 — проверяю Docker."
if ! command -v docker >/dev/null 2>&1; then
  log "Docker не найден, ставлю через официальный скрипт get.docker.com…"
  curl -fsSL https://get.docker.com | sh
  systemctl enable --now docker
else
  log "Docker уже установлен: $(docker --version)"
fi

docker compose version >/dev/null 2>&1 || die "docker compose (плагин) не найден — обновите Docker Engine до версии с встроенным compose."

log "Шаг 2/6 — папка установки: ${INSTALL_DIR}"
mkdir -p "${INSTALL_DIR}/backups"
cd "${INSTALL_DIR}"

log "Шаг 3/6 — скачиваю docker-compose.prod.yml, скрипты обновления/отката и шаблон Caddyfile."
curl -fsSL "${REPO_RAW_BASE}/docker-compose.prod.yml" -o docker-compose.prod.yml
curl -fsSL "${REPO_RAW_BASE}/Caddyfile.template" -o Caddyfile.template
curl -fsSL "${REPO_RAW_BASE}/.env.example" -o .env.example
curl -fsSL "${REPO_RAW_BASE}/update.sh" -o update.sh
curl -fsSL "${REPO_RAW_BASE}/rollback.sh" -o rollback.sh
chmod +x update.sh rollback.sh

if [[ -f .env ]]; then
  warn ".env уже существует — оставляю как есть (повторный запуск install.sh не перезатирает настройки)."
else
  log "Шаг 4/6 — настройка (домен, почта для TLS-сертификата)."
  read -rp "Домен сайта (например attest0.ru): " DOMAIN
  read -rp "Email для Let's Encrypt (уведомления об истечении сертификата): " ACME_EMAIL
  read -rp "Владелец GitHub-репозитория с образами [${GHCR_OWNER_DEFAULT}]: " GHCR_OWNER
  GHCR_OWNER="${GHCR_OWNER:-$GHCR_OWNER_DEFAULT}"

  DB_PASSWORD="$(openssl rand -hex 24)"
  SECRET_KEY="$(openssl rand -hex 32)"

  cp .env.example .env
  sed -i.bak \
    -e "s#^DOMAIN=.*#DOMAIN=${DOMAIN}#" \
    -e "s#^ACME_EMAIL=.*#ACME_EMAIL=${ACME_EMAIL}#" \
    -e "s#^GHCR_OWNER=.*#GHCR_OWNER=${GHCR_OWNER}#" \
    -e "s#^DB_PASSWORD=.*#DB_PASSWORD=${DB_PASSWORD}#" \
    -e "s#^SECRET_KEY=.*#SECRET_KEY=${SECRET_KEY}#" \
    -e "s#^IMAGE_TAG=.*#IMAGE_TAG=latest#" \
    .env
  rm -f .env.bak
  echo "latest" > .current_version

  warn "Заполните в ${INSTALL_DIR}/.env перед боевым запуском: блок SMTP_* (реальная"
  warn "почта) и INVOICE_PAYEE_NAME/INN/ACCOUNT/BANK (реквизиты для оплаты по счёту —"
  warn "ключей ЮKassa для первого запуска ещё не будет, см. раздел 1 в UPDATE.md)."
  warn "Без этого backend откажется стартовать в production-режиме — это осознанная"
  warn "защита от запуска с незаполненными настройками, не баг."
fi

log "Шаг 5/6 — генерирую Caddyfile из шаблона."
load_env .env
envsubst '${DOMAIN} ${ACME_EMAIL}' < Caddyfile.template > Caddyfile

log "Шаг 6/6 — скачиваю образы и запускаю."
docker compose -f docker-compose.prod.yml --env-file .env pull
docker compose -f docker-compose.prod.yml --env-file .env up -d

log "Готово. Сайт будет доступен на https://${DOMAIN} — Caddy получает"
log "сертификат автоматически, это может занять 1-2 минуты."
log "Проверить статус: cd ${INSTALL_DIR} && docker compose -f docker-compose.prod.yml ps"
