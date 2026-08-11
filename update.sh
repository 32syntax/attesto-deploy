#!/usr/bin/env bash
# Attest0 — обновление до конкретной версии образов.
#
# Использование:
#   ./update.sh 0.24.3
#
# Версию берите со страницы Releases/Tags GitHub-репозитория с исходным
# кодом — та же версия, что в frontend/package.json на момент релиза.
# Версия не подбирается автоматически специально: обновление — осознанное
# действие оператора, а не молчаливый автопул чего попало на боевой сервер.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

log()  { echo -e "\033[1;32m[update]\033[0m $*"; }
warn() { echo -e "\033[1;33m[update]\033[0m $*"; }
die()  { echo -e "\033[1;31m[update]\033[0m $*" >&2; exit 1; }

# Читает .env построчно как KEY=VALUE и экспортирует — не "source",
# который выполняет файл как bash-код: значение с пробелом без кавычек
# (например, INVOICE_PAYEE_NAME=ООО Ромашка) превращается в отдельную
# команду и падает с "Ромашка: command not found", а спецсимволы в
# значении (случайный `, $(...), ; ) выполнились бы как код. Здесь —
# только присваивание переменной, без интерпретации содержимого.
load_env() {
  local key value
  while IFS='=' read -r key value; do
    [[ -z "${key}" || "${key}" == \#* ]] && continue
    export "${key}=${value}"
  done < "$1"
}

[[ -f .env ]] || die ".env не найден — запустите из папки установки (обычно /opt/attest0)."
[[ $# -eq 1 ]] || die "Использование: ./update.sh <версия>, например ./update.sh 0.24.3"
NEW_VERSION="$1"

CURRENT_VERSION="$(cat .current_version 2>/dev/null || echo "неизвестна")"
log "Текущая версия: ${CURRENT_VERSION}"
log "Новая версия:   ${NEW_VERSION}"

if [[ "${NEW_VERSION}" == "${CURRENT_VERSION}" ]]; then
  warn "Уже на версии ${NEW_VERSION} — делать нечего."
  exit 0
fi

COMPOSE=(docker compose -f docker-compose.prod.yml --env-file .env)
load_env .env

log "Шаг 1/6 — бэкап базы данных перед обновлением."
mkdir -p backups
TIMESTAMP="$(date -u +%Y%m%dT%H%M%SZ)"
BACKUP_FILE="backups/attest0_before_${NEW_VERSION}_${TIMESTAMP}.dump"
"${COMPOSE[@]}" exec -T db pg_dump -U "${DB_USER:-attesto}" -d "${DB_NAME:-attesto}" -F c > "${BACKUP_FILE}"
[[ -s "${BACKUP_FILE}" ]] || die "Бэкап получился пустым — обновление остановлено, ничего не менялось."
log "Бэкап сохранён: ${BACKUP_FILE} ($(du -h "${BACKUP_FILE}" | cut -f1))"

log "Шаг 2/6 — запоминаю текущую версию для отката (rollback.sh без аргументов вернёт именно её)."
echo "${CURRENT_VERSION}" > .previous_version
echo "${BACKUP_FILE}" > .previous_backup

log "Шаг 3/6 — переключаю IMAGE_TAG на ${NEW_VERSION} в .env."
sed -i.bak -e "s#^IMAGE_TAG=.*#IMAGE_TAG=${NEW_VERSION}#" .env
rm -f .env.bak
# Без этого повторного load_env шелл всё ещё держит старый IMAGE_TAG,
# экспортированный ДО перезаписи файла (см. вызов load_env .env выше) —
# а переменная окружения shell'а перебивает --env-file для docker compose,
# так что pull/up ниже тихо продолжили бы использовать старую версию,
# даже когда сам .env на диске уже правильный (баг был найден именно так:
# update.sh отрапортовал успех на 0.27.7, а реально работал контейнер
# 0.26.1 — см. rollback.sh, где этот повторный вызов уже был).
load_env .env

log "Шаг 4/6 — скачиваю образы ${NEW_VERSION}."
if ! "${COMPOSE[@]}" pull; then
  warn "Не удалось скачать образы ${NEW_VERSION} — откатываю .env обратно, ничего не трогал."
  sed -i.bak -e "s#^IMAGE_TAG=.*#IMAGE_TAG=${CURRENT_VERSION}#" .env && rm -f .env.bak
  die "Обновление прервано на этапе скачивания образов."
fi

log "Шаг 5/6 — прогоняю миграции базы данных и пересоздаю контейнеры."
"${COMPOSE[@]}" up -d
log "Жду, пока backend пройдёт healthcheck (до 60 секунд)…"
for _ in $(seq 1 30); do
  STATUS="$("${COMPOSE[@]}" ps --format json backend 2>/dev/null | grep -o '"Health":"[a-z]*"' | cut -d'"' -f4 || true)"
  [[ "${STATUS}" == "healthy" ]] && break
  sleep 2
done

if [[ "${STATUS:-}" != "healthy" ]]; then
  warn "backend не стал healthy за отведённое время."
  warn "Логи: docker compose -f docker-compose.prod.yml logs backend --tail=100"
  die "Обновление применено, но backend нездоров — рассмотрите откат: ./rollback.sh"
fi

log "Шаг 6/6 — версия обновлена и подтверждена healthcheck'ом."
echo "${NEW_VERSION}" > .current_version
{
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) ${CURRENT_VERSION} -> ${NEW_VERSION} backup=${BACKUP_FILE}"
} >> update.log

log "Готово. Текущая версия: ${NEW_VERSION}."
log "Если через несколько минут что-то работает не так — ./rollback.sh вернёт ${CURRENT_VERSION} и восстановит БД из бэкапа выше."

# Бэкапы старше 30 дней не нужны бесконечно — но раньше 5 последних не трогаем,
# даже если им больше 30 дней (минимальная глубина отката). Без mapfile/массивов
# намеренно — переносимо на любой bash, не только версии 4+.
OLD_BACKUPS="$(find backups -name 'attest0_before_*.dump' -mtime +30 | sort | head -n -5 2>/dev/null || true)"
if [[ -n "${OLD_BACKUPS}" ]]; then
  OLD_COUNT="$(echo "${OLD_BACKUPS}" | wc -l | tr -d ' ')"
  log "Удаляю ${OLD_COUNT} бэкап(ов) старше 30 дней (оставляю не менее 5 последних)."
  echo "${OLD_BACKUPS}" | xargs rm -f
fi
