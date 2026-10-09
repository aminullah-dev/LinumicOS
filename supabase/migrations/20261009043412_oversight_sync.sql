-- Oversight register in the cloud (fixes a data-loss bug).
--
-- Before this migration export_inventory() carried no `oversight` section and import_inventory() ignored it.
-- A signed-in client that loaded from the cloud therefore received an empty register and wrote it over its
-- local copy. Now:
--   * the register is stored per repository in public.oversight_repos (slug -> the app's OversightRepo JSON);
--   * export_inventory() adds `oversight`; import_inventory() merges the incoming register into the table;
--   * merging never deletes: a repository missing from an upload is kept, and an entry only changes when the
--     incoming copy was observed at the same time or later. An upload without `oversight` changes nothing.
-- The client also merges (HybridInventoryStore), so an older server can't wipe the register either.
--
-- No audit trigger on purpose: these rows are a cache of read-only GitHub observations that every sweep
-- refreshes (every 30 minutes); auditing them would copy the whole register into audit_events each time.

create table public.oversight_repos (
  slug text primary key check (slug ~ '^[^/[:space:]]+/[^/[:space:]]+$'),
  entry jsonb not null check (jsonb_typeof(entry) = 'object'),
  observed_at timestamptz,
  updated_at timestamptz not null default now()
);

alter table public.oversight_repos enable row level security;
create policy "admins read oversight" on public.oversight_repos for select to authenticated using ((select private.is_admin()));
create policy "admins add oversight" on public.oversight_repos for insert to authenticated with check ((select private.is_admin()));
create policy "admins update oversight" on public.oversight_repos for update to authenticated
  using ((select private.is_admin())) with check ((select private.is_admin()));
-- No delete policy: the register only grows; a repository that disappears from GitHub keeps its last entry.

create or replace function public.export_oversight()
returns jsonb language plpgsql stable security invoker set search_path = ''
as $$
begin
  perform public.assert_admin();
  return coalesce((select jsonb_agg(o.entry order by o.observed_at desc nulls last, o.slug) from public.oversight_repos o), '[]'::jsonb);
end $$;
revoke execute on function public.export_oversight() from public, anon;
grant execute on function public.export_oversight() to authenticated;

-- Merges OversightRepo objects by slug. Never deletes. Ignores anything that isn't an array of objects with a slug.
create or replace function public.upsert_oversight(rows jsonb)
returns void language plpgsql volatile security invoker set search_path = ''
as $$
begin
  perform public.assert_admin();
  if rows is null or jsonb_typeof(rows) <> 'array' then return; end if;
  insert into public.oversight_repos as t (slug, entry, observed_at)
  select distinct on (x->>'slug') x->>'slug', x, (x->>'observedAt')::timestamptz
  from jsonb_array_elements(rows) x
  where jsonb_typeof(x) = 'object' and coalesce(x->>'slug', '') <> ''
  order by x->>'slug', (x->>'observedAt')::timestamptz desc nulls last
  on conflict (slug) do update set entry = excluded.entry, observed_at = excluded.observed_at, updated_at = now()
  where t.entry is distinct from excluded.entry
    and (t.observed_at is null or excluded.observed_at >= t.observed_at);
end $$;
revoke execute on function public.upsert_oversight(jsonb) from public, anon;
grant execute on function public.upsert_oversight(jsonb) to authenticated;

-- Keep the existing whole-inventory functions as the "core" and wrap them, so their long bodies aren't copied.
alter function public.export_inventory() rename to export_inventory_core;
alter function public.import_inventory(jsonb) rename to import_inventory_core;

create or replace function public.export_inventory()
returns jsonb language plpgsql stable security invoker set search_path = ''
as $$
begin
  perform public.assert_admin();
  return public.export_inventory_core() || jsonb_build_object('oversight', public.export_oversight());
end $$;
revoke execute on function public.export_inventory() from public, anon;
grant execute on function public.export_inventory() to authenticated;

-- import_inventory_core keeps its "replace" rule for products and the rest; the oversight register is merged.
create or replace function public.import_inventory(doc jsonb)
returns void language plpgsql volatile security invoker set search_path = ''
as $$
begin
  perform public.import_inventory_core(doc);
  if doc ? 'oversight' then
    perform public.upsert_oversight(doc->'oversight');
  end if;
end $$;
revoke execute on function public.import_inventory(jsonb) from public, anon;
grant execute on function public.import_inventory(jsonb) to authenticated;
