-- Product renamed to Linumic OS: update the access-denied message only. Behaviour is unchanged.
create or replace function public.assert_admin()
returns void language plpgsql stable set search_path = ''
as $$
begin
  if current_user not in ('postgres', 'service_role', 'supabase_admin') and not private.is_admin() then
    raise exception 'Not authorised: Linumic OS admins only' using errcode = '42501';
  end if;
end $$;
revoke execute on function public.assert_admin() from public, anon;
grant execute on function public.assert_admin() to authenticated;
