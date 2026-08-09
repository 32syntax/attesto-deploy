#!/usr/bin/env bash
# Attest0 — откат последнего обновления: возвращает предыдущую версию
# образов И восстанавливает базу данных из бэкапа, снятого update.sh
# прямо перед тем обновлением.
#
# Использование:
#   ./rollback.sh
#
# ВНИМАНИЕ: восстановление БД из бэкапа стирает все данные, записанные
# ПОСЛЕ этого бэкапа (новые обращения в поддержку, результаты тестов и
# т.д. за время между обновлением и откатом). Если обновление было час
# назад и всё это время системой пользовались — те действия потеряются.
# Если нужно просто вернуть версию кода БЕЗ отката данных (например,
# проблема чисто визуальная, а не в БД) — используйте
# ./update.sh <предыдущая_версия> вместо этого скрипта.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

log()  { echo -e "\033[1;32m[rollback]\033[0m $*"; }
warn() { echo -e "\033[1;33m[rollback]\033[0m $*"; }
die()  { echo -e "\033[1;31m[rollback]\033[0m $*" >&2; exit 1; }

[[ -f .env ]] || die ".env не найден — запустите из папки установки (обычно /opt/attest0)."
[[ -f .previous_version ]] || die "Нет записи о предыдущей версии (.previous_version) — откатывать нечего. Обновление ./update.sh ни разу не запускалось из этой папки?"
[[ -f .previous_backup ]] || die "Нет записи о бэкапе (.previous_backup) — не могу безопасно откатить БД."

PREV_VERSION="$(cat .previous_version)"
BACKUP_FILE="$(cat .previous_backup)"
CURRENT_VERSION="$(cat .current_version 2>/dev/null || echo "неизвестна")"

[[ -f "${BACKUP_FILE}" ]] || die "Файл бэкапа ${BACKUP_FILE} не найден на диске (удалили вручную?). Список доступных: ls -la backups/"

echo
warn "Откат: ${CURRENT_VERSION} -> ${PREV_VERSION}"
warn "База данных будет восстановлена из: ${BACKUP_FILE}"
warn "Это сотрёт все данные, записанные в систему ПОСЛЕ этого бэкапа."
echo
read -rp "Продолжить? Введите 'да' для подтверждения: " CONFIRM
[[ "${CONFIRM}" == "да" ]] || { log "Отменено."; exit 0; }

COMPOSE=(docker compose -f docker-compose.prod.yml --env-file .env)
# shellcheck disable=SC1091
source .env

log "Шаг 1/5 — останавливаю backend и celery-worker (база остаётся поднятой)."
"${COMPOSE[@]}" stop backend celery-worker frontend

log "Шаг 2/5 — восстанавливаю базу данных из ${BACKUP_FILE}."
"${COMPOSE[@]}" exec -T db pg_restore -U "${DB_USER:-attesto}" -d "${DB_NAME:-attesto}" --clean --if-exists < "${BACKUP_FILE}"

log "Шаг 3/5 — переключаю IMAGE_TAG обратно на ${PREV_VERSION}."
sed -i.bak -e "s#^IMAGE_TAG=.*#IMAGE_TAG=${PREV_VERSION}#" .env
rm -f .env.bak
# shellcheck disable=SC1091
source .env

log "Шаг 4/5 — скачиваю образы версии ${PREV_VERSION} (если их уже нет локально) и поднимаю сервисы."
"${COMPOSE[@]}" pull
"${COMPOSE[@]}" up -d

log "Жду, пока backend пройдёт healthcheck (до 60 секунд)…"
for _ in $(seq 1 30); do
  STATUS="$("${COMPOSE[@]}" ps --format json backend 2>/dev/null | grep -o '"Health":"[a-z]*"' | cut -d'"' -f4 || true)"
  [[ "${STATUS}" == "healthy" ]] && break
  sleep 2
done
[[ "${STATUS:-}" == "healthy" ]] || warn "backend не стал healthy за отведённое время — смотрите: docker compose -f docker-compose.prod.yml logs backend --tail=100"

log "Шаг 5/5 — готово."
echo "${PREV_VERSION}" > .current_version
rm -f .previous_version .previous_backup
{
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) ROLLBACK ${CURRENT_VERSION} -> ${PREV_VERSION} restored=${BACKUP_FILE}"
} >> update.log

log "Текущая версия: ${PREV_VERSION}."
