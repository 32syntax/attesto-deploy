#!/usr/bin/env bash
# Attest0 — ежедневный бэкап БД по cron (ATT-057 §4: "Production: ежедневно").
#
# update.sh уже делает бэкап перед каждым релизом, но между релизами
# может пройти несколько дней без единого свежего снимка — этот скрипт
# закрывает именно тот промежуток. Использование: ./backup_daily.sh
# (без аргументов, обычно вызывается из crontab).
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

log()  { echo -e "\033[1;32m[backup]\033[0m $*"; }
die()  { echo -e "\033[1;31m[backup]\033[0m $*" >&2; exit 1; }

# Тот же безопасный построчный парсер .env, что в update.sh/rollback.sh —
# "source" на значении с пробелом/спецсимволом без кавычек упал бы или
# выполнился бы как код.
load_env() {
  local key value
  while IFS='=' read -r key value; do
    [[ -z "${key}" || "${key}" == \#* ]] && continue
    export "${key}=${value}"
  done < "$1"
}

[[ -f .env ]] || die ".env не найден — запустите из папки установки (обычно /opt/attest0)."
load_env .env

COMPOSE=(docker compose -f docker-compose.prod.yml --env-file .env)

mkdir -p backups
TIMESTAMP="$(date -u +%Y%m%dT%H%M%SZ)"
BACKUP_FILE="backups/attest0_daily_${TIMESTAMP}.dump"

"${COMPOSE[@]}" exec -T db pg_dump -U "${DB_USER:-attesto}" -d "${DB_NAME:-attesto}" -F c > "${BACKUP_FILE}"
if [[ ! -s "${BACKUP_FILE}" ]]; then
  rm -f "${BACKUP_FILE}"
  die "Бэкап получился пустым — db-контейнер не отвечал? Ничего не сохранено."
fi
shasum -a 256 "${BACKUP_FILE}" > "${BACKUP_FILE}.sha256"
log "Бэкап сохранён: ${BACKUP_FILE} ($(du -h "${BACKUP_FILE}" | cut -f1))"
echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) daily backup=${BACKUP_FILE}" >> backup.log

# Ретеншен ATT-057: ежедневные снимки старше 30 дней не нужны бесконечно,
# но не менее 7 последних (глубина отката ~неделя) оставляем всегда, даже
# если им больше 30 дней. Отдельно от чистки в update.sh (тот трогает
# только attest0_before_*.dump, эта — только attest0_daily_*.dump), чтобы
# ежедневные и предрелизные бэкапы не съедали лимит друг друга.
OLD_BACKUPS="$(find backups -name 'attest0_daily_*.dump' -mtime +30 | sort | head -n -7 2>/dev/null || true)"
if [[ -n "${OLD_BACKUPS}" ]]; then
  OLD_COUNT="$(echo "${OLD_BACKUPS}" | wc -l | tr -d ' ')"
  log "Удаляю ${OLD_COUNT} ежедневных бэкап(ов) старше 30 дней (оставляю не менее 7 последних)."
  echo "${OLD_BACKUPS}" | while read -r f; do rm -f "${f}" "${f}.sha256"; done
fi
