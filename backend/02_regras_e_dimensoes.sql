-- =====================================================================
-- 02_regras_e_dimensoes.sql
-- Carga inicial das dimensões estáticas e das regras de negócio.
-- =====================================================================

-- ---------------------------------------------------------------------
-- RN-07 | Categorização temática dos exames (11 grupos + Outros).
-- A primeira regra (menor prioridade) cujo padrão casar com a descrição
-- define a categoria. A ordem resolve ambiguidades, por exemplo:
--   'HEMOGLOBINA GLICADA' deve cair em Glicêmico (20) antes de Hematologia (80);
--   'TESTE RÁPIDO HIV EM GESTANTE' cai em Infecciosas/IST (50), e o
--   vínculo com o pré-natal é registrado pela flag_pre_natal.
-- ---------------------------------------------------------------------
insert into public.regra_categoria (prioridade, padrao, categoria) values
  (10, 'PEZINHO|BIOTINIDASE|FENILALANINA', 'Outros'),
  (20, 'GLICAD|GLICOSILAD|GLICOSE|GLICEMI|INSULINA', 'Monitoramento Glicêmico'),
  (30, 'TRIGLICER|COLESTEROL|(^|[^A-Z])HDL([^A-Z]|$)|(^|[^A-Z])LDL([^A-Z]|$)', 'Perfil Lipídico'),
  (40, 'CITOPATOL|COLO D[EO] [UÚ]TER|COLO UTERINO|MAMOGRAFIA|OBSTETRIC|TRANSVAGINAL|MAMARIA|GINECOLOGICA|COLPOSCOPIA|GONADOTROFINA|BETA HCG|GRAVIDEZ', 'Saúde da Mulher e Pré-natal'),
  (50, 'HIV|HTLV|S[IÍ]FILIS|TREPON|VDRL|FTA-ABS|HEPATITE|HBV|HBSAG|HCV|ANTI-HB|TOXOPLASMA|CITOMEGALOVIRUS|RUBEOLA|HERPES|VARICELA|DENGUE|ZIKA|CHIKUNGUNYA|MALARIA|PLASMODIO|BAAR|TUBERCULOS|ESCARRO|CULTURA DE BACT|UROCULTURA|LARVAS', 'Doenças Infecciosas e IST'),
  (60, 'URINA|EAS / EQU|UREIA|CREATININA|POTASSIO|SODIO|MICROALBUMINA', 'Função Renal e Urinária'),
  (70, 'TRANSAMINASE|BILIRRUBINA|FOSFATASE ALCALINA|GAMA-GLUTAMIL|AMILASE|LIPASE|PROTEINAS TOTAIS|DESIDROGENASE LATICA', 'Função Hepática e Pancreática'),
  (80, 'HEMOGRAMA|HEMOSSEDIMENTA|FERRITINA|FERRO|TRANSFERRINA|VITAMINA B12|HEMOGLOBINA|GRUPO ABO|FATOR RH|COMPATIBILIDADE|ANTIGLOBULINA|TROMBOPLASTINA|PROTROMBINA|COAGULA|RETICULOCITOS', 'Hematologia'),
  (90, 'PROTE[IÍ]NA C REATIVA|ANTIESTREPTOLISINA|FATOR REUMATOIDE', 'Marcadores Inflamatórios'),
  (100, 'ACIDO URICO', 'Ácido Úrico'),
  (110, 'TIREOESTIMULANTE|(^|[^A-Z])TSH([^A-Z]|$)|TIROXINA|TRIIODOTIRONINA|TESTOSTERONA|ESTRADIOL|FOLICULO|LUTEINIZANTE|PROGESTERONA|PROLACTINA|CORTISOL', 'Tireoide e Endocrinologia'),
  (120, 'ULTRASSONOGRAFIA|RADIOGRAFIA|TOMOGRAFIA|RESSONANCIA|ELETROCARDIOGRAMA|ECOCARDIOGRAFIA|HOLTER|CATETERISMO|DENSITOMETRIA|AUDIOMETRIA|ESPIROMETRIA|POLISSONOGRAFIA', 'Imagem e Métodos Gráficos')
on conflict (prioridade) do update
  set padrao = excluded.padrao, categoria = excluded.categoria;

-- ---------------------------------------------------------------------
-- Dimensão SEXO (domínio fechado do e-SUS)
-- ---------------------------------------------------------------------
insert into public.dim_sexo (id_sexo, descricao, sigla) values
  (1, 'Feminino', 'F'),
  (2, 'Masculino', 'M'),
  (9, 'Não Informado', 'N')
on conflict (id_sexo) do nothing;

-- ---------------------------------------------------------------------
-- Dimensão FAIXA ETÁRIA (21 valores originais + hierarquia)
-- RN-05 | Ciclos de vida: criança 0–9 anos; adolescente 10–19 (OMS);
--         adulto 20–59; idoso 60+ (Estatuto da Pessoa Idosa, Lei 10.741/2003).
-- ---------------------------------------------------------------------
insert into public.dim_faixa_etaria
  (id_faixa, descricao, ordem, idade_min, idade_max, faixa_agrupada, ciclo_vida) values
  (1, 'Menos de 01 ano', 1, 0, 0, 'Menos de 01 ano', 'Criança (0–9)'),
  (2, '01 ano', 2, 1, 1, '01 a 04 anos', 'Criança (0–9)'),
  (3, '02 anos', 3, 2, 2, '01 a 04 anos', 'Criança (0–9)'),
  (4, '03 anos', 4, 3, 3, '01 a 04 anos', 'Criança (0–9)'),
  (5, '04 anos', 5, 4, 4, '01 a 04 anos', 'Criança (0–9)'),
  (6, '05 a 09 anos', 6, 5, 9, '05 a 09 anos', 'Criança (0–9)'),
  (7, '10 a 14 anos', 7, 10, 14, '10 a 14 anos', 'Adolescente (10–19)'),
  (8, '15 a 19 anos', 8, 15, 19, '15 a 19 anos', 'Adolescente (10–19)'),
  (9, '20 a 24 anos', 9, 20, 24, '20 a 24 anos', 'Adulto (20–59)'),
  (10, '25 a 29 anos', 10, 25, 29, '25 a 29 anos', 'Adulto (20–59)'),
  (11, '30 a 34 anos', 11, 30, 34, '30 a 34 anos', 'Adulto (20–59)'),
  (12, '35 a 39 anos', 12, 35, 39, '35 a 39 anos', 'Adulto (20–59)'),
  (13, '40 a 44 anos', 13, 40, 44, '40 a 44 anos', 'Adulto (20–59)'),
  (14, '45 a 49 anos', 14, 45, 49, '45 a 49 anos', 'Adulto (20–59)'),
  (15, '50 a 54 anos', 15, 50, 54, '50 a 54 anos', 'Adulto (20–59)'),
  (16, '55 a 59 anos', 16, 55, 59, '55 a 59 anos', 'Adulto (20–59)'),
  (17, '60 a 64 anos', 17, 60, 64, '60 a 64 anos', 'Idoso (60+)'),
  (18, '65 a 69 anos', 18, 65, 69, '65 a 69 anos', 'Idoso (60+)'),
  (19, '70 a 74 anos', 19, 70, 74, '70 a 74 anos', 'Idoso (60+)'),
  (20, '75 a 79 anos', 20, 75, 79, '75 a 79 anos', 'Idoso (60+)'),
  (21, '80 anos ou mais', 21, 80, null, '80 anos ou mais', 'Idoso (60+)')
on conflict (id_faixa) do nothing;

-- ---------------------------------------------------------------------
-- Dimensão TIPO DE ATENDIMENTO
-- RN-06 | Natureza da demanda: agendada/programada = Programada;
--         'Consulta no Dia' = Espontânea; urgência = Urgência.
-- ---------------------------------------------------------------------
insert into public.dim_atendimento (descricao, tipo_demanda) values
  ('Consulta Agendada', 'Programada'),
  ('Consulta Agendada Programada / Cuidado Continuado', 'Programada'),
  ('Consulta no Dia', 'Espontânea'),
  ('Atendimento de Urgência', 'Urgência')
on conflict (descricao) do nothing;

-- ---------------------------------------------------------------------
-- Dimensão UNIDADE (unidade do estudo; outras podem ser incluídas)
-- ---------------------------------------------------------------------
insert into public.dim_unidade (nome, municipio, uf) values
  ('UBASF Antônio Gomes', 'Jaguaribe', 'CE')
on conflict (nome) do nothing;
