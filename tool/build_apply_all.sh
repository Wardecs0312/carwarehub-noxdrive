#!/bin/sh
# Собирает supabase/apply_all.sql из миграций для вставки в SQL Editor Supabase.
set -e
cd "$(dirname "$0")/.."
out=supabase/apply_all.sql
{
  echo
  echo '-- Все миграции одним файлом для вставки в SQL Editor Supabase (собрано из supabase/migrations/0001-0004).'
  echo '-- Выполнять один раз. Если в проекте уже есть объекты с такими же именами,'
  echo '-- скрипт сразу остановится со списком совпадений и ничего не создаст.'
  echo
  cat supabase/precheck.sql
  for f in supabase/migrations/*.sql; do
    echo
    echo "-- ===== $f ====="
    cat "$f"
  done
} > "$out"
echo "$out"
