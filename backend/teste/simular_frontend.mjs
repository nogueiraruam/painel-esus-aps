// Simula EXATAMENTE o que o frontend (Lovable) fará: ler o arquivo com SheetJS,
// enviar em lotes de 5.000 linhas e finalizar a carga, como usuário autenticado.
import XLSX from 'xlsx'; import pg from 'pg';
const arquivo = process.argv[2];
const wb = XLSX.readFile(arquivo);
const linhas = XLSX.utils.sheet_to_json(wb.Sheets[wb.SheetNames[0]], { raw: true, defval: null });
console.log('linhas lidas:', linhas.length, 'exemplo:', linhas[0]);
const c = new pg.Client({ host: '/var/tmp/pg', port: 5433, user: 'postgres', database: 'tcc' });
await c.connect();
await c.query("set role authenticated");
await c.query("select set_config('request.jwt.claim.sub','11111111-1111-1111-1111-111111111111',false), set_config('request.jwt.claims','{\"email\":\"ruan@teste.com\"}',false)");
const { rows: [{ id }] } = await c.query("select public.fn_iniciar_carga(1, $1) as id", [arquivo.split('/').pop()]);
for (let i = 0; i < linhas.length; i += 5000) {
  const r = await c.query("select public.fn_enviar_lote($1, $2::jsonb) n", [id, JSON.stringify(linhas.slice(i, i + 5000))]);
  console.log('lote', i / 5000 + 1, '->', r.rows[0].n);
}
const fim = await c.query("select public.fn_finalizar_carga($1) r", [id]);
console.log(JSON.stringify(fim.rows[0].r, null, 1));
await c.end();
