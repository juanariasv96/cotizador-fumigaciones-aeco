-- =====================================================================
-- PESTAÑA "PENDIENTES": servicios agendados que ya pasaron y siguen sin
-- reporte del tecnico.
--
-- No necesita tablas nuevas: la lista se arma leyendo visitas_programadas
-- y descartando las que ya tienen reportes_visita o reportes_lamparas_uv.
-- Lo unico que falta son PERMISOS DE LECTURA para el rol "vendedor", que
-- hasta ahora no entraba a ninguna vista de oficina.
--
-- Idempotente: se puede correr mas de una vez sin romper nada.
-- =====================================================================


-- ---------------------------------------------------------------------
-- PASO 1. es_vendedor(), mismo patron que es_dueno() / es_asistente().
-- ---------------------------------------------------------------------
create or replace function public.es_vendedor()
returns boolean
language sql
stable
as $$
  select exists (
    select 1 from public.perfiles_usuario
    where id = auth.uid() and rol = 'vendedor' and activo = true
  );
$$;


-- ---------------------------------------------------------------------
-- PASO 2. Ventas necesita leer perfiles_usuario para poder ver DE QUIEN
-- es el servicio que no se hizo (sin esto la lista le sale con el
-- tecnico en blanco, que es justo el dato que importa).
--
-- Se suma como politica nueva; no se toca ninguna de las que ya existen
-- (perfiles_select_propio / perfiles_select_dueno / perfiles_select_oficina).
-- Postgres combina politicas permisivas del mismo tipo con OR.
-- ---------------------------------------------------------------------
drop policy if exists "perfiles_select_ventas" on public.perfiles_usuario;
create policy "perfiles_select_ventas" on public.perfiles_usuario
  for select to authenticated using (public.es_vendedor());


-- ---------------------------------------------------------------------
-- PASO 3. visita_tecnicos: lectura para todo el equipo autenticado, para
-- que la lista de pendientes pueda decir que tecnico tenia la visita
-- cuando hay mas de uno asignado. Si la tabla no existe todavia en este
-- proyecto, el bloque no hace nada en vez de tronar.
--
-- La app degrada sola: si esta lectura falla, cae a tecnico_asignado.
-- ---------------------------------------------------------------------
do $$
begin
  if exists (
    select 1 from information_schema.tables
    where table_schema = 'public' and table_name = 'visita_tecnicos'
  ) then
    execute 'alter table public.visita_tecnicos enable row level security';
    execute 'drop policy if exists "visita_tecnicos_select_equipo" on public.visita_tecnicos';
    execute 'create policy "visita_tecnicos_select_equipo" on public.visita_tecnicos
               for select to authenticated using (true)';
    execute 'grant select on public.visita_tecnicos to authenticated';
  end if;
end $$;
