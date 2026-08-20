-- =====================================================================
-- CLIENTES DUPLICADOS: fusion + candados para que no se repitan
-- SEDES en los servicios (un cliente con varias sucursales)
-- FRECUENCIAS Semanal y Quincenal
--
-- Idempotente: se puede correr mas de una vez sin romper nada.
--
-- POR QUE SE DUPLICABAN LOS CLIENTES
-- upsertCliente() buscaba al cliente existente exigiendo que coincidieran
-- el nombre Y el telefono exacto. Si el telefono venia vacio o distinto,
-- daba de alta uno nuevo. Asi, "EDIFICIO MITT", "Edificio MITT" y
-- "Edificio MITT " quedaron como tres clientes, cada uno con su propio
-- plan de trabajo, y el calendario mostraba las visitas repetidas.
-- =====================================================================


-- ---------------------------------------------------------------------
-- PASO 1. Sede/sucursal en los servicios.
--
-- Un mismo cliente puede tener varios servicios del mismo tipo cuando son
-- sucursales distintas (un colegio con 5 escuelas, cada una con su precio
-- y su calendario). La sede es lo que las distingue: sin ella, esos casos
-- legitimos se veian igual que un alta duplicada por error.
-- ---------------------------------------------------------------------
alter table public.servicios_cliente add column if not exists sede text;


-- ---------------------------------------------------------------------
-- PASO 2. Frecuencias Semanal y Quincenal (y Cuatrimestral, que ya se
-- ofrecia en la cotizacion pero el catalogo de servicios no aceptaba).
-- ---------------------------------------------------------------------
alter table public.servicios_cliente
  drop constraint if exists servicios_cliente_frecuencia_cat_check;

alter table public.servicios_cliente
  add constraint servicios_cliente_frecuencia_cat_check
  check (frecuencia_cat is null or frecuencia_cat in
    ('Semanal','Quincenal','Mensual','Bimestral','Trimestral','Cuatrimestral','Semestral','Anual'));


-- ---------------------------------------------------------------------
-- PASO 2b. La numeracion de estaciones es POR TIPO DE DISPOSITIVO.
--
-- La restriccion original era unique(cliente_id, numero): un cliente no
-- podia tener dos estaciones con el mismo numero. Pero en campo cada
-- familia se numera aparte: los cebaderos van 1..27 y las lamparas UV
-- tambien empiezan en 1. Con la regla vieja, un cliente con cebaderos y
-- lamparas chocaba consigo mismo (fue justo lo que paso al fusionar BEST
-- BOX: 3 lamparas 1-3 contra 27 cebaderos 1-27).
--
-- La regla correcta es unique(cliente_id, tipo_estacion, numero), que
-- respeta las etiquetas fisicas que el tecnico ve pegadas en el sitio.
-- Verificado contra las 782 estaciones actuales: cero choques.
-- ---------------------------------------------------------------------
alter table public.estaciones drop constraint if exists estaciones_cliente_id_numero_key;

create unique index if not exists ux_estaciones_cliente_tipo_numero
  on public.estaciones (cliente_id, tipo_estacion, numero);


-- ---------------------------------------------------------------------
-- PASO 3. Respaldo antes de fusionar.
--
-- Copia intacta de las tres tablas que se van a tocar. Si algo sale mal,
-- de aqui se recupera todo. No borrar hasta haber revisado el resultado.
-- ---------------------------------------------------------------------
drop table if exists public.respaldo_clientes_20260820;
create table public.respaldo_clientes_20260820 as
  select * from public.clientes;

drop table if exists public.respaldo_servicios_20260820;
create table public.respaldo_servicios_20260820 as
  select * from public.servicios_cliente;

drop table if exists public.respaldo_visitas_20260820;
create table public.respaldo_visitas_20260820 as
  select * from public.visitas_programadas;


-- ---------------------------------------------------------------------
-- PASO 4. Nombre normalizado: mayusculas, sin acentos, sin espacios ni
-- signos. Es la clave con la que se decide si dos filas son el mismo
-- cliente. La calcula la base (columna generada), no la app, para que
-- nunca se desincronicen.
-- ---------------------------------------------------------------------
alter table public.clientes drop column if exists nombre_norm;
alter table public.clientes add column nombre_norm text
  generated always as (
    upper(regexp_replace(
      translate(nombre, 'ÁÉÍÓÚÜÑáéíóúüñ', 'AEIOUUNaeiouun'),
      '[^A-Za-z0-9]', '', 'g'))
  ) stored;


-- ---------------------------------------------------------------------
-- PASO 5. Mapa de fusion: por cada grupo de duplicados se elige UN
-- sobreviviente y los demas se marcan para reasignar.
--
-- Gana el que esta escrito en MAYUSCULAS (es la carga principal, la que
-- trae servicios y visitas) y, a igualdad, el mas antiguo.
-- ---------------------------------------------------------------------
drop table if exists public.mapa_fusion_clientes;
create table public.mapa_fusion_clientes as
with ranked as (
  select id, nombre, nombre_norm, fecha_creacion,
         first_value(id) over (
           partition by nombre_norm
           order by (nombre = upper(nombre)) desc, fecha_creacion asc, id asc
         ) as sobreviviente,
         count(*) over (partition by nombre_norm) as veces
  from public.clientes
)
select id as viejo, sobreviviente as nuevo, nombre_norm
from ranked
where veces > 1 and id <> sobreviviente;


-- ---------------------------------------------------------------------
-- PASO 6. Reasignar TODO lo que cuelga de un cliente duplicado hacia su
-- sobreviviente. Recorre las llaves foraneas reales de la base, para no
-- olvidar ninguna tabla (cotizaciones, servicios, visitas, estaciones,
-- avisos, contratos, reportes, hoteles, etc.).
-- ---------------------------------------------------------------------
do $$
declare r record;
begin
  for r in
    select tc.table_schema as esquema, tc.table_name as tabla, kcu.column_name as columna
    from information_schema.table_constraints tc
    join information_schema.key_column_usage kcu
      on kcu.constraint_name = tc.constraint_name
     and kcu.constraint_schema = tc.constraint_schema
    join information_schema.constraint_column_usage ccu
      on ccu.constraint_name = tc.constraint_name
     and ccu.constraint_schema = tc.constraint_schema
    where tc.constraint_type = 'FOREIGN KEY'
      and ccu.table_schema = 'public'
      and ccu.table_name  = 'clientes'
      and ccu.column_name = 'id'
      and tc.table_name not like 'respaldo_%'
  loop
    execute format(
      'update %I.%I t set %I = m.nuevo from public.mapa_fusion_clientes m where t.%I = m.viejo',
      r.esquema, r.tabla, r.columna, r.columna);
    raise notice 'Reasignado: %.% (%)', r.esquema, r.tabla, r.columna;
  end loop;
end $$;


-- ---------------------------------------------------------------------
-- PASO 7. Borrar las fichas duplicadas (ya vacias) y dejar el nombre del
-- sobreviviente en MAYUSCULAS, que es el formato elegido.
-- ---------------------------------------------------------------------
delete from public.clientes c
  using public.mapa_fusion_clientes m
 where c.id = m.viejo;

update public.clientes c
   set nombre = upper(nombre)
  from (select distinct nuevo from public.mapa_fusion_clientes) s
 where c.id = s.nuevo and c.nombre <> upper(c.nombre);


-- ---------------------------------------------------------------------
-- PASO 8. Candados para que no vuelva a pasar.
--
-- 8a. Un cliente no puede repetirse por nombre normalizado.
-- 8b. Un servicio no puede tener dos visitas el mismo dia (eso siempre
--     es un plan generado dos veces, nunca un caso real).
-- ---------------------------------------------------------------------
create unique index if not exists ux_clientes_nombre_norm
  on public.clientes (nombre_norm);

create unique index if not exists ux_visitas_servicio_fecha
  on public.visitas_programadas (servicio_id, fecha_programada);


-- ---------------------------------------------------------------------
-- PASO 9. Resultado.
-- ---------------------------------------------------------------------
select
  (select count(*) from public.respaldo_clientes_20260820) as clientes_antes,
  (select count(*) from public.clientes)                   as clientes_despues,
  (select count(*) from public.mapa_fusion_clientes)       as fichas_fusionadas,
  (select count(*) from public.servicios_cliente)          as servicios,
  (select count(*) from public.visitas_programadas)        as visitas;
