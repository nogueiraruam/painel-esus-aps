# Painel Preditivo e-SUS APS

Código do Trabalho de Conclusão de Curso do **MBA em Data Science e Analytics (USP/Esalq)**:

> **Dashboard preditivo para gestão da demanda de exames na atenção primária com dados do e-SUS**
> Autor: Ruan Carlos Damião Nogueira Rêgo · Orientador: Prof. Jacques Henrique Dias

O painel organiza o *Relatório gerencial de exames* do e-SUS APS (PEC) da UBASF Antônio Gomes, em Jaguaribe/CE, num modelo dimensional em esquema estrela. Sobre esse modelo, ele calcula 10 medidas, prevê o volume semanal de exames com suavização exponencial simples, segmenta perfis de demanda com K-means e gera um resumo executivo com insights acionáveis. Tudo é recalculado automaticamente a cada nova carga.

**Fonte dos dados:** e-SUS APS (PEC) do município de Jaguaribe/CE, *Relatório gerencial de exames*, com as linhas Dia, Exame, Tipo de atendimento, Sexo e Faixa etária.
**Os dados de saúde não estão neste repositório** (LGPD): só o código, as regras e os resultados agregados.

## Arquitetura
- **Backend:** PostgreSQL (Lovable Cloud). O ETL, as regras de negócio, as medidas e os modelos estão escritos em SQL/PL/pgSQL, com segurança em nível de linha (RLS).
- **Frontend:** React/TypeScript gerado na plataforma Lovable a partir das especificações da pasta `lovable/`.
- **Análise e validação dos modelos:** Python (pandas, statsmodels, scikit-learn) em notebook Jupyter.

## Estrutura
| Pasta / arquivo | Conteúdo |
|---|---|
| `backend/01_estrutura.sql` | Modelo estrela (fato_exame + 6 dimensões), staging, log de cargas e RLS |
| `backend/02_regras_e_dimensoes.sql` | Regras de categorização dos exames (RN-07) e dimensões estáticas |
| `backend/03_etl.sql` | ETL: `fn_iniciar_carga`, `fn_enviar_lote`, `fn_finalizar_carga` e `fn_cancelar_carga` (RN-01 a RN-11) |
| `backend/04_previsao.sql` | Série semanal e previsão SES / ETS(A,N,N), retreinada a cada carga (RN-12 e RN-13) |
| `backend/05_medidas.sql` | Camada semântica: `fn_dashboard` (10 medidas) e `fn_opcoes_filtro` |
| `backend/06_perfis.sql` | Perfis de demanda: K-means em PL/pgSQL, com k escolhido pela silhueta (RN-14 e RN-15) |
| `backend/07_atualizacao_perfis.sql` | Atualização incremental para bancos que já tinham as migrações 01 a 05 |
| `backend/08_insights.sql` | Resumo executivo e motor de insights por regras (RN-16 a RN-23) |
| `backend/teste/` | Simulação da carga feita pelo frontend (Node + SheetJS) e stub do Supabase para teste local |
| `python/TCC_Ruan_Modelagem.ipynb` | Auditoria, análise exploratória, comparação de 8 modelos de previsão e K-means |
| `lovable/` | Prompts/especificações usados para aplicar o backend e gerar o frontend |
| `figs/`, `diagramas/` | Figuras do TCC e fontes Graphviz dos diagramas |

## Teste local do backend
```bash
psql -f backend/teste/00_stub_supabase_local.sql      # simula auth.uid() e os perfis anon/authenticated
for f in 01 02 03 04 05 06 08; do psql -f backend/${f}_*.sql; done
cd backend/teste && npm install xlsx pg && node simular_frontend.mjs <relatorio_exportado_do_esus.xlsb>
```
