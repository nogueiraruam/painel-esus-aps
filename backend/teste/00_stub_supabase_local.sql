-- Apenas para TESTE LOCAL: simula objetos que o Supabase/Lovable Cloud já possui.
do $$ begin create role anon nologin; exception when duplicate_object then null; end $$;
do $$ begin create role authenticated nologin; exception when duplicate_object then null; end $$;
create schema auth;
create function auth.uid() returns uuid language sql stable as
$$ select nullif(current_setting('request.jwt.claim.sub', true),'')::uuid $$;
create function auth.jwt() returns jsonb language sql stable as
$$ select coalesce(nullif(current_setting('request.jwt.claims', true),''),'{}')::jsonb $$;
grant usage on schema auth, public to anon, authenticated;
grant execute on all functions in schema auth to anon, authenticated;
