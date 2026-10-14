-- Применено в боевой базе CarWareHubNoxDrive 14.10.2026. Повторный запуск безопасен.
-- Закрытие анонимного доступа к security definer функциям до конца.
-- 0006 снял право у роли anon, но у части функций осталось общее право PUBLIC (=X/postgres), через которое anon вызывает их.
-- Роли authenticated и service_role получают право явно, затем снимается PUBLIC и anon. Данные не затрагиваются.
do $do$ declare f record; begin
  for f in select p.oid::regprocedure as sig from pg_proc p
           where p.pronamespace = 'public'::regnamespace and p.prosecdef
             and has_function_privilege('anon', p.oid, 'execute') loop
    execute format('grant execute on function %s to authenticated, service_role', f.sig);
    execute format('revoke execute on function %s from public, anon', f.sig);
  end loop;
end $do$;
