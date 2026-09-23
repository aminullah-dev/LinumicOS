-- Keep the security-definer admin check out of the API-exposed schema (advisor lints 0028/0029).
-- RLS policies refer to the function by OID, so they keep working after the move.
create schema if not exists private;
revoke all on schema private from public, anon;
grant usage on schema private to authenticated;

alter function public.is_admin() set schema private;
revoke execute on function private.is_admin() from public, anon;
grant execute on function private.is_admin() to authenticated;

create or replace function public.assert_admin()
returns void language plpgsql stable set search_path = ''
as $$
begin
  if current_user not in ('postgres', 'service_role', 'supabase_admin') and not private.is_admin() then
    raise exception 'Not authorised: Linumic Command Center admins only' using errcode = '42501';
  end if;
end $$;
revoke execute on function public.assert_admin() from public, anon;
grant execute on function public.assert_admin() to authenticated;
