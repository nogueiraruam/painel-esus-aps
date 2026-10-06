-- =====================================================================
-- 03_etl.sql
-- ETL (Extract-Transform-Load) executado DENTRO do banco de dados.
--
-- Fluxo de uma carga (chamado pelo frontend, nesta ordem):
--   1) fn_iniciar_carga(unidade, arquivo)   -> abre o log e devolve id_carga
--   2) fn_enviar_lote(id_carga, linhas)     -> grava lotes de até 5.000 linhas
--                                              na staging (texto bruto)
--   3) fn_finalizar_carga(id_carga)         -> valida, transforma, substitui o
--                                              período e carrega o fato
--                                              (transação única: tudo ou nada)
-- =====================================================================

-- ---------------------------------------------------------------------
-- Funções auxiliares de transformação
-- ---------------------------------------------------------------------

-- Normaliza texto: remove espaços duplicados e nas pontas.
create or replace function public.fn_normalizar(p text)
returns text language sql immutable as $$
  select nullif(regexp_replace(btrim(coalesce(p,'')), '\s+', ' ', 'g'), '')
$$;

-- Chave de comparação de cabeçalhos: minúsculas e sem acentos.
create or replace function public.fn_chave(p text)
returns text language sql immutable as $$
  select lower(translate(public.fn_normalizar(p),
         'ÁÀÂÃÄÉÈÊËÍÌÎÏÓÒÔÕÖÚÙÛÜÇáàâãäéèêëíìîïóòôõöúùûüç',
         'AAAAAEEEEIIIIOOOOOUUUUCaaaaaeeeeiiiiooooouuuuc'))
$$;

-- RN-01 | Conversão de data. O e-SUS exporta a data como número serial do
-- Excel (dias desde 30/12/1899). Aceita também 'DD/MM/AAAA' e 'AAAA-MM-DD'.
create or replace function public.fn_converter_data(p text)
returns date language plpgsql immutable as $$
declare v text := public.fn_normalizar(p);
begin
  if v is null then return null; end if;
  if v ~ '^\d{5}(\.0+)?$' then
    return date '1899-12-30' + split_part(v, '.', 1)::int;
  elsif v ~ '^\d{2}/\d{2}/\d{4}$' then
    return to_date(v, 'DD/MM/YYYY');
  elsif v ~ '^\d{4}-\d{2}-\d{2}' then
    return left(v, 10)::date;
  end if;
  return null;
exception when others then
  return null;
end $$;

-- RN-07 | Categoria temática: primeira regra ativa (por prioridade) que casar.
create or replace function public.fn_classificar_exame(p_descricao text)
returns text language sql stable as $$
  select coalesce(
    (select r.categoria
       from public.regra_categoria r
      where r.ativo and upper(p_descricao) ~ r.padrao
      order by r.prioridade
      limit 1),
    'Outros')
$$;

-- RN-08 | Rastreamento oncológico (preventivo): citopatológico do colo do
-- útero, coleta de material do colo e mamografia.
create or replace function public.fn_flag_rastreamento(p_descricao text)
returns boolean language sql immutable as $$
  select upper(p_descricao) ~ '(CITOPATOL|COLETA DE MATERIAL DO COLO|MAMOGRAFIA)'
     and upper(p_descricao) !~ '(BIOPSIA|ANATOMO)'
$$;

-- RN-09 | Pré-natal: exames de gestante, parceiro(a) de gestante e obstétricos.
create or replace function public.fn_flag_pre_natal(p_descricao text)
returns boolean language sql immutable as $$
  select upper(p_descricao) ~ '(GESTANTE|OBSTETRIC|GRAVIDEZ|GONADOTROFINA)'
$$;

-- RN-10 | Grupo SIGTAP a partir dos 6 primeiros dígitos do código.
create or replace function public.fn_grupo_sigtap(p_codigo text)
returns text language sql immutable as $$
  select case
    when p_codigo !~ '^\d{10}$'      then 'Código próprio e-SUS'
    when left(p_codigo,4) = '0201'   then '02.01 Coleta de material'
    when left(p_codigo,4) = '0202'   then '02.02 Diagnóstico em laboratório clínico'
    when left(p_codigo,4) = '0203'   then '02.03 Anatomopatologia e citopatologia'
    when left(p_codigo,4) = '0204'   then '02.04 Radiologia'
    when left(p_codigo,4) = '0205'   then '02.05 Ultrassonografia'
    when left(p_codigo,4) = '0206'   then '02.06 Tomografia'
    when left(p_codigo,4) = '0207'   then '02.07 Ressonância magnética'
    when left(p_codigo,4) = '0211'   then '02.11 Métodos diagnósticos em especialidades'
    when left(p_codigo,4) = '0213'   then '02.13 Diagnóstico em vigilância epidemiológica'
    when left(p_codigo,4) = '0214'   then '02.14 Diagnóstico por teste rápido'
    else '02.xx Outros procedimentos diagnósticos'
  end
$$;

-- Garante a existência de todas as datas do intervalo na dimensão tempo.
create or replace function public.fn_preencher_tempo(p_ini date, p_fim date)
returns integer language plpgsql security definer set search_path = public as $$
declare n integer;
begin
  insert into public.dim_tempo
  select to_char(d,'YYYYMMDD')::int,
         d,
         extract(year from d),
         case when extract(month from d) <= 6 then 1 else 2 end,
         extract(quarter from d),
         extract(month from d),
         (array['Janeiro','Fevereiro','Março','Abril','Maio','Junho','Julho',
                'Agosto','Setembro','Outubro','Novembro','Dezembro'])[extract(month from d)],
         to_char(d,'YYYY-MM'),
         extract(day from d),
         extract(dow from d),
         (array['Domingo','Segunda','Terça','Quarta','Quinta','Sexta','Sábado'])[extract(dow from d)+1],
         extract(dow from d) in (0,6),
         ini_sem,
         -- RN-04 | Semana epidemiológica (MS): domingo a sábado; a semana
         -- pertence ao ano em que cai a sua quarta-feira.
         ((extract(doy from ini_sem + 3)::int - 1) / 7) + 1,
         extract(year from ini_sem + 3)
    from (select d::date as d, (d::date - extract(dow from d)::int) as ini_sem
            from generate_series(p_ini, p_fim, interval '1 day') g(d)) s
  on conflict (id_data) do nothing;
  get diagnostics n = row_count;
  return n;
end $$;

-- ---------------------------------------------------------------------
-- 1) INICIAR CARGA
-- ---------------------------------------------------------------------
create or replace function public.fn_iniciar_carga(p_id_unidade integer, p_nome_arquivo text)
returns bigint language plpgsql security definer set search_path = public as $$
declare v_id bigint;
begin
  if auth.uid() is null then
    raise exception 'Acesso negado: usuário não autenticado.';
  end if;
  if not exists (select 1 from dim_unidade where id_unidade = p_id_unidade and ativo) then
    raise exception 'Unidade % inexistente ou inativa.', p_id_unidade;
  end if;

  -- cargas abandonadas há mais de 1 hora são encerradas como rejeitadas
  update log_carga
     set status = 'rejeitada', finalizado_em = now(),
         mensagem = 'Carga abandonada (não finalizada em 1 hora).'
   where status = 'em_andamento' and iniciado_em < now() - interval '1 hour';

  insert into log_carga (id_unidade, nome_arquivo, usuario_id, usuario_email)
  values (p_id_unidade, left(coalesce(p_nome_arquivo,'sem_nome'), 200),
          auth.uid(), auth.jwt() ->> 'email')
  returning id_carga into v_id;
  return v_id;
end $$;

-- ---------------------------------------------------------------------
-- 2) ENVIAR LOTE  (array JSON com os cabeçalhos originais do e-SUS)
--    [{"Dia":46091,"Exame":"0214010236 - ...","Tipo de Atendimento":"...",
--      "Sexo":"Feminino","Faixa Etária":"30 a 34 anos"}, ...]
-- ---------------------------------------------------------------------
create or replace function public.fn_enviar_lote(p_id_carga bigint, p_linhas jsonb)
returns integer language plpgsql security definer set search_path = public as $$
declare
  k_dia text; k_exa text; k_ate text; k_sex text; k_fx text;
  k text; v_offset integer; n integer;
begin
  if auth.uid() is null then
    raise exception 'Acesso negado: usuário não autenticado.';
  end if;
  if not exists (select 1 from log_carga
                  where id_carga = p_id_carga and status = 'em_andamento'
                    and usuario_id = auth.uid()) then
    raise exception 'Carga % não está aberta para este usuário.', p_id_carga;
  end if;
  if jsonb_typeof(p_linhas) <> 'array' or jsonb_array_length(p_linhas) = 0 then
    raise exception 'Lote vazio ou em formato inválido.';
  end if;
  if jsonb_array_length(p_linhas) > 5000 then
    raise exception 'Lote acima de 5.000 linhas. Divida o envio.';
  end if;

  -- RN-02 | Validação de layout: os 5 cabeçalhos obrigatórios devem existir
  -- (comparação sem acento e sem diferenciar maiúsculas).
  for k in select jsonb_object_keys(p_linhas -> 0) loop
    case fn_chave(k)
      when 'dia'                 then k_dia := k;
      when 'exame'               then k_exa := k;
      when 'tipo de atendimento' then k_ate := k;
      when 'sexo'                then k_sex := k;
      when 'faixa etaria'        then k_fx  := k;
      else null;
    end case;
  end loop;
  if k_dia is null or k_exa is null or k_ate is null or k_sex is null or k_fx is null then
    raise exception 'Layout inválido. Colunas obrigatórias: Dia, Exame, Tipo de Atendimento, Sexo, Faixa Etária.';
  end if;

  select coalesce(max(n_linha), 0) into v_offset from stg_exame where id_carga = p_id_carga;

  insert into stg_exame (id_carga, n_linha, dia_raw, exame_raw, atendimento_raw, sexo_raw, faixa_raw)
  select p_id_carga, v_offset + o,
         r ->> k_dia, fn_normalizar(r ->> k_exa), fn_normalizar(r ->> k_ate),
         fn_normalizar(r ->> k_sex), fn_normalizar(r ->> k_fx)
    from jsonb_array_elements(p_linhas) with ordinality as t(r, o);
  get diagnostics n = row_count;

  update log_carga set linhas_recebidas = linhas_recebidas + n where id_carga = p_id_carga;
  return n;
end $$;

-- ---------------------------------------------------------------------
-- 3) FINALIZAR CARGA  (validar -> dimensões -> substituir período -> fato)
-- ---------------------------------------------------------------------
create or replace function public.fn_finalizar_carga(p_id_carga bigint)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  c           log_carga%rowtype;
  v_receb     integer;
  v_valid     integer;
  v_rejei     integer;
  v_min       date;
  v_max       date;
  v_subst     integer;
  v_novos     integer;
  v_erros     text;
  v_res       jsonb;
begin
  if auth.uid() is null then
    raise exception 'Acesso negado: usuário não autenticado.';
  end if;
  select * into c from log_carga where id_carga = p_id_carga for update;
  if c.id_carga is null or c.status <> 'em_andamento' or c.usuario_id <> auth.uid() then
    raise exception 'Carga % não está aberta para este usuário.', p_id_carga;
  end if;

  -- uma carga por unidade de cada vez (evita substituições concorrentes)
  perform pg_advisory_xact_lock(c.id_unidade);

  -- ---------- VALIDAÇÃO (linha a linha, na staging) ----------
  update stg_exame s
     set data_ok = fn_converter_data(s.dia_raw)
   where s.id_carga = p_id_carga;

  update stg_exame s
     set erro = nullif(concat_ws('; ',
           case when s.data_ok is null            then 'data inválida' end,
           case when s.data_ok > current_date     then 'data futura' end,
           case when s.data_ok < date '2013-01-01' then 'data anterior ao e-SUS APS' end,
           case when s.exame_raw is null
                  or s.exame_raw !~ '^\S+\s+-\s+.+' then 'exame sem código' end,
           case when s.atendimento_raw is null    then 'tipo de atendimento vazio' end,
           case when not exists (select 1 from dim_sexo x
                                  where fn_chave(x.descricao) = fn_chave(s.sexo_raw))
                                                  then 'sexo fora do domínio' end,
           case when not exists (select 1 from dim_faixa_etaria f
                                  where fn_chave(f.descricao) = fn_chave(s.faixa_raw))
                                                  then 'faixa etária fora do domínio' end
         ), '')
   where s.id_carga = p_id_carga;

  select count(*), count(*) filter (where erro is null), count(*) filter (where erro is not null),
         min(data_ok) filter (where erro is null), max(data_ok) filter (where erro is null)
    into v_receb, v_valid, v_rejei, v_min, v_max
    from stg_exame where id_carga = p_id_carga;

  select string_agg(e || ' (' || n || ')', '; ' order by n desc) into v_erros
    from (select unnest(string_to_array(erro, '; ')) e, count(*) n
            from stg_exame where id_carga = p_id_carga and erro is not null
           group by 1) z;

  -- RN-03 | Tolerância a erros: a carga inteira é rejeitada se não houver
  -- linhas válidas ou se mais de 5% das linhas forem inválidas.
  if v_valid = 0 or v_rejei::numeric / greatest(v_receb,1) > 0.05 then
    update log_carga
       set status = 'rejeitada', finalizado_em = now(),
           linhas_validas = v_valid, linhas_rejeitadas = v_rejei,
           mensagem = 'Carga rejeitada: ' || v_rejei || ' de ' || v_receb ||
                      ' linhas inválidas. ' || coalesce(v_erros,'')
     where id_carga = p_id_carga;
    delete from stg_exame where id_carga = p_id_carga;
    return jsonb_build_object('status','rejeitada','linhas_recebidas',v_receb,
                              'linhas_rejeitadas',v_rejei,'erros',v_erros);
  end if;

  -- ---------- DIMENSÕES (membros novos) ----------
  perform fn_preencher_tempo(v_min, v_max);

  insert into dim_atendimento (descricao, tipo_demanda)
  select distinct s.atendimento_raw, 'Não classificada'
    from stg_exame s
   where s.id_carga = p_id_carga and s.erro is null
     and not exists (select 1 from dim_atendimento a where a.descricao = s.atendimento_raw);

  with novos as (
    select distinct on (cod) cod, descr
      from (select btrim(split_part(s.exame_raw, ' - ', 1)) as cod,
                   btrim(substr(s.exame_raw, strpos(s.exame_raw, ' - ') + 3)) as descr
              from stg_exame s
             where s.id_carga = p_id_carga and s.erro is null) z
     where not exists (select 1 from dim_exame e where e.codigo = z.cod)
     order by cod
  )
  insert into dim_exame (codigo, descricao, origem_codigo, grupo_sigtap, categoria,
                         flag_rastreamento, flag_pre_natal)
  select cod, descr,
         case when cod ~ '^\d{10}$' then 'SIGTAP' else 'e-SUS (código próprio)' end,
         fn_grupo_sigtap(cod), fn_classificar_exame(descr),
         fn_flag_rastreamento(descr), fn_flag_pre_natal(descr)
    from novos;
  get diagnostics v_novos = row_count;

  -- ---------- RN-11 | SUBSTITUIÇÃO DO PERÍODO ----------
  -- Remove do fato todos os registros da unidade entre a menor e a maior
  -- data do arquivo e grava as linhas do arquivo. Reenviar um período não
  -- duplica contagens; linhas idênticas legítimas são preservadas (sem
  -- deduplicação, pois a base não possui identificador de paciente).
  delete from fato_exame
   where id_unidade = c.id_unidade
     and id_data between to_char(v_min,'YYYYMMDD')::int and to_char(v_max,'YYYYMMDD')::int;
  get diagnostics v_subst = row_count;

  insert into fato_exame (id_data, id_unidade, id_exame, id_atendimento, id_sexo, id_faixa, id_carga)
  select to_char(s.data_ok,'YYYYMMDD')::int, c.id_unidade, e.id_exame, a.id_atendimento,
         x.id_sexo, f.id_faixa, p_id_carga
    from stg_exame s
    join dim_exame e        on e.codigo = btrim(split_part(s.exame_raw, ' - ', 1))
    join dim_atendimento a  on a.descricao = s.atendimento_raw
    join dim_sexo x         on fn_chave(x.descricao) = fn_chave(s.sexo_raw)
    join dim_faixa_etaria f on fn_chave(f.descricao) = fn_chave(s.faixa_raw)
   where s.id_carga = p_id_carga and s.erro is null;
  get diagnostics v_valid = row_count;

  -- ---------- LOG + minimização de dados (LGPD art. 6º, III) ----------
  update log_carga
     set status = 'concluida', finalizado_em = now(),
         linhas_validas = v_valid, linhas_rejeitadas = v_rejei,
         data_min = v_min, data_max = v_max,
         linhas_substituidas = v_subst, exames_novos = v_novos,
         mensagem = case when v_rejei > 0 then 'Linhas descartadas: ' || v_erros end
   where id_carga = p_id_carga;
  delete from stg_exame where id_carga = p_id_carga;

  -- ---------- retreino automático: previsão (04) e perfis de demanda (06) ----------
  perform fn_pos_carga(c.id_unidade);

  v_res := jsonb_build_object(
    'status','concluida','linhas_recebidas',v_receb,'linhas_carregadas',v_valid,
    'linhas_rejeitadas',v_rejei,'periodo_inicio',v_min,'periodo_fim',v_max,
    'linhas_substituidas',v_subst,'exames_novos',v_novos,'erros',v_erros);
  return v_res;
end $$;

-- Reaplica as regras de categoria (após editar regra_categoria).
create or replace function public.fn_reclassificar_exames()
returns integer language plpgsql security definer set search_path = public as $$
declare n integer;
begin
  if auth.uid() is null then raise exception 'Acesso negado.'; end if;
  update dim_exame
     set categoria = fn_classificar_exame(descricao),
         flag_rastreamento = fn_flag_rastreamento(descricao),
         flag_pre_natal = fn_flag_pre_natal(descricao)
   where classificado_por = 'regra';
  get diagnostics n = row_count;
  return n;
end $$;

-- Cancela uma carga aberta (usado pelo frontend quando ocorre erro no envio).
create or replace function public.fn_cancelar_carga(p_id_carga bigint, p_motivo text default null)
returns void language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'Acesso negado.'; end if;
  update log_carga
     set status = 'rejeitada', finalizado_em = now(),
         mensagem = 'Carga cancelada: ' || coalesce(left(p_motivo, 300), 'erro no envio')
   where id_carga = p_id_carga and status = 'em_andamento' and usuario_id = auth.uid();
  delete from stg_exame where id_carga = p_id_carga;
end $$;
