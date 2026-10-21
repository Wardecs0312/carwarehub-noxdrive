-- [2] Голосовое управление: перенос WT_ThemeResourcesDay/Night больше не останавливает услугу.
-- На Q05 с прошивкой SWC.5328 папок /resources/appdata/tinnove/WT_ThemeResources* нет,
-- mv падает «Is a directory», и услуга обрывалась перед очисткой /data/local/tmp (21.10.2026).
-- Исходный батник nox.bat эту ошибку не замечает и идёт дальше — делаем так же.
-- Применено в бою 21.10.2026 через REST (PATCH scenarios.steps), здесь — то же самое на SQL.

update scenarios sc
   set steps = (
     select jsonb_agg(
              case when s ->> 'type' = 'shell'
                    and s ->> 'cmd' like 'mv %WT_ThemeResources%'
                   then s || '{"ignore_errors": true}'::jsonb
                   else s end
              order by i)
       from jsonb_array_elements(sc.steps) with ordinality as t(s, i))
 where sc.service_id = (select id from services where id = 2)
   and exists (select 1 from jsonb_array_elements(sc.steps) s
                where s ->> 'cmd' like 'mv %WT_ThemeResources%'
                  and coalesce((s ->> 'ignore_errors')::boolean, false) = false);
