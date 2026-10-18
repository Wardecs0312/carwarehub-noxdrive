-- 1) Задание снимается по таймауту, только если программа мастера пропала со связи
--    (нет отметки «в сети» 5 минут) или оно идёт дольше 3 часов. Раньше любое задание
--    старше 30 минут считалось зависшим, и долгая установка голоса снималась посреди работы.
-- 2) Зависшие трансляции закрываются сами: программа мастера пропала со связи (3 минуты)
--    или запрос так и не был принят за 10 минут.
create or replace function expire_stale_jobs() returns void
language sql security definer set search_path = public as $$
  update activations a set status = 'failed', finished_at = now(), log = coalesce(a.log, 'timeout')
  where a.status = 'running'
    and (a.created_at < now() - interval '3 hours'
         or (a.created_at < now() - interval '30 minutes'
             and not exists (select 1 from master_presence p
                             where p.master_id = a.master_id
                               and p.last_seen > now() - interval '5 minutes')));

  update stream_sessions s set status = 'ended', ended_at = now()
  where s.status in ('requested', 'live')
    and ((s.status = 'requested' and s.created_at < now() - interval '10 minutes')
         or (s.created_at < now() - interval '3 minutes'
             and not exists (select 1 from master_presence p
                             where p.master_id = s.master_id
                               and p.last_seen > now() - interval '3 minutes')));
$$;
revoke all on function expire_stale_jobs() from public, anon, authenticated;

-- 3) «Включение Overlay» в «Установке системных приложений»: если оверлея на этой прошивке
--    нет, шаг не валит всю услугу (первый оверлей включается, остальные — по возможности).
update scenarios
set steps = (
  select jsonb_agg(
           case when e->>'type' = 'shell' and e->>'cmd' like 'cmd overlay enable %'
                then e || '{"ignore_errors": true}'::jsonb else e end
           order by ord)
  from jsonb_array_elements(steps) with ordinality as t(e, ord)
)
where steps::text like '%cmd overlay enable %';
