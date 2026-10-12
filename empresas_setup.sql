-- =====================================================================
-- CRM AECO · Fase 1: Empresas, grupos, sucursales y contactos (oct 2026)
-- =====================================================================
-- Qué hace (todo es ADITIVO: no borra ni cambia datos existentes):
--   1. Respaldo de la tabla clientes antes de tocar nada.
--   2. Tablas nuevas: grupos_empresa, empresas, contactos_cliente.
--   3. clientes (= sucursales) ganan: empresa_id, facturar_aparte,
--      odoo_partner_id.
--   4. Cada cliente que ya existe recibe su propia empresa con el mismo
--      nombre (y sus datos fiscales, si tenía). Después, al revisar el
--      Excel de Odoo, se juntan las sucursales que son de la misma empresa.
--   5. Trigger: todo cliente nuevo que entre sin empresa recibe la suya
--      automáticamente (así la cotización y el resto de la app siguen
--      funcionando igual que hoy).
--   6. Seguridad: RLS de equipo + GRANT (las dos, lección de clics_whatsapp).
-- Se puede correr dos veces sin problema.
-- =====================================================================

-- 1) Respaldo (solo la primera vez)
create table if not exists public.respaldo_clientes_20261012 as
  select * from public.clientes;

-- 2) Tablas nuevas
create table if not exists public.grupos_empresa (
  id              uuid primary key default gen_random_uuid(),
  nombre          text not null,
  notas           text,
  fecha_creacion  timestamptz not null default now()
);

create table if not exists public.empresas (
  id                 uuid primary key default gen_random_uuid(),
  nombre             text not null,
  razon_social       text,
  rfc                text,
  tipo_persona       text check (tipo_persona is null or tipo_persona in ('fisica','moral')),
  regimen_fiscal     text,
  uso_cfdi           text,
  cp_fiscal          text,
  email_facturacion  text,
  modo_facturacion   text not null default 'por_sucursal'
                     check (modo_facturacion in ('por_sucursal','consolidada','variable')),
  grupo_id           uuid references public.grupos_empresa(id) on delete set null,
  notas              text,
  odoo_partner_id    integer,
  creado_por         uuid references auth.users(id),
  fecha_creacion     timestamptz not null default now(),
  fecha_actualizacion timestamptz not null default now()
);
create index if not exists empresas_rfc_idx on public.empresas (rfc);
create index if not exists empresas_grupo_idx on public.empresas (grupo_id);
create index if not exists empresas_odoo_idx on public.empresas (odoo_partner_id);

create table if not exists public.contactos_cliente (
  id                   uuid primary key default gen_random_uuid(),
  empresa_id           uuid not null references public.empresas(id) on delete cascade,
  cliente_id           uuid references public.clientes(id) on delete cascade,  -- null = toda la empresa
  nombre               text not null,
  puesto               text,
  telefono             text,
  email                text,
  recibe_certificados  boolean not null default false,
  recibe_facturas      boolean not null default false,
  notas                text,
  fecha_creacion       timestamptz not null default now()
);
create index if not exists contactos_empresa_idx on public.contactos_cliente (empresa_id);
create index if not exists contactos_cliente_idx on public.contactos_cliente (cliente_id);

-- 3) clientes = sucursales
alter table public.clientes add column if not exists empresa_id uuid references public.empresas(id) on delete set null;
alter table public.clientes add column if not exists facturar_aparte boolean not null default false;
alter table public.clientes add column if not exists odoo_partner_id integer;
create index if not exists clientes_empresa_idx on public.clientes (empresa_id);

-- 4) Una empresa por cada cliente que todavía no tiene (con sus datos fiscales)
do $$
declare c record; nueva uuid;
begin
  for c in select * from public.clientes where empresa_id is null loop
    insert into public.empresas (nombre, razon_social, rfc, tipo_persona, regimen_fiscal,
                                 uso_cfdi, cp_fiscal, email_facturacion, creado_por)
    values (c.nombre, c.razon_social, c.rfc,
            case when c.tipo_persona in ('fisica','moral') then c.tipo_persona end,
            c.regimen_fiscal, c.uso_cfdi, c.cp_fiscal, c.email_facturacion, c.creado_por)
    returning id into nueva;
    update public.clientes set empresa_id = nueva where id = c.id;
  end loop;
end $$;

-- 5) Trigger: cliente nuevo sin empresa -> se le crea una
create or replace function public.crear_empresa_para_cliente()
returns trigger language plpgsql security definer set search_path = public as $$
declare nueva uuid;
begin
  if new.empresa_id is null then
    insert into public.empresas (nombre, razon_social, rfc, regimen_fiscal, uso_cfdi,
                                 cp_fiscal, email_facturacion, creado_por)
    values (new.nombre, new.razon_social, new.rfc, new.regimen_fiscal, new.uso_cfdi,
            new.cp_fiscal, new.email_facturacion, new.creado_por)
    returning id into nueva;
    new.empresa_id := nueva;
  end if;
  return new;
end $$;
drop trigger if exists trg_crear_empresa_para_cliente on public.clientes;
create trigger trg_crear_empresa_para_cliente
  before insert on public.clientes
  for each row execute function public.crear_empresa_para_cliente();

-- fecha_actualizacion de empresas al editar
create or replace function public.tocar_fecha_actualizacion_empresa()
returns trigger language plpgsql as $$
begin new.fecha_actualizacion := now(); return new; end $$;
drop trigger if exists trg_empresas_fecha on public.empresas;
create trigger trg_empresas_fecha before update on public.empresas
  for each row execute function public.tocar_fecha_actualizacion_empresa();

-- 6) Seguridad: mismo criterio de equipo que clientes
alter table public.grupos_empresa    enable row level security;
alter table public.empresas          enable row level security;
alter table public.contactos_cliente enable row level security;

do $$
declare t text;
begin
  foreach t in array array['grupos_empresa','empresas','contactos_cliente'] loop
    execute format('drop policy if exists "%1$s_equipo_select" on public.%1$s', t);
    execute format('create policy "%1$s_equipo_select" on public.%1$s for select to authenticated using (true)', t);
    execute format('drop policy if exists "%1$s_equipo_insert" on public.%1$s', t);
    execute format('create policy "%1$s_equipo_insert" on public.%1$s for insert to authenticated with check (true)', t);
    execute format('drop policy if exists "%1$s_equipo_update" on public.%1$s', t);
    execute format('create policy "%1$s_equipo_update" on public.%1$s for update to authenticated using (true) with check (true)', t);
    execute format('drop policy if exists "%1$s_equipo_delete" on public.%1$s', t);
    execute format('create policy "%1$s_equipo_delete" on public.%1$s for delete to authenticated using (true)', t);
    execute format('grant select, insert, update, delete on public.%1$s to authenticated', t);
  end loop;
end $$;

-- Verificación: las 3 primeras deben ser > 0; la última debe ser 0.
select 'empresas creadas'            as que, count(*) from public.empresas
union all select 'clientes en respaldo',       count(*) from public.respaldo_clientes_20261012
union all select 'clientes con empresa',       count(*) from public.clientes where empresa_id is not null
union all select 'clientes SIN empresa (debe ser 0)', count(*) from public.clientes where empresa_id is null;
