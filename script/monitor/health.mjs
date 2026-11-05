// Chequeo de salud de Bietix (solo lectura: no firma nada ni necesita billetera).
//
// Uso:   RPC_URL=<url> CHAIN_ID=421614 node script/monitor/health.mjs
// Salida: un informe en Markdown y el código de salida 0 = todo bien, 1 = advertencias, 2 = crítico.
// Lo corre .github/workflows/monitor.yml cada 15 minutos; también se puede correr a mano.
import { JsonRpcProvider, Contract, formatUnits } from "../../frontend/vendor/ethers.min.js";
import { NETWORKS } from "../../frontend/config.js";
import { runChecks } from "./checks.mjs";

const chainId = Number(process.env.CHAIN_ID || 421614);
const net = NETWORKS[chainId];
if (!net) {
  console.error(`Red ${chainId} no configurada en frontend/config.js`);
  process.exit(2);
}
if (!net.contracts.vault) {
  console.log(`Bietix todavía no está desplegado en ${net.name}: nada que revisar.`);
  process.exit(0);
}
const rpc = process.env.RPC_URL || net.rpc;
const provider = new JsonRpcProvider(rpc, chainId, { staticNetwork: true });

const results = await runChecks({ provider, net, Contract, formatUnits });
const worst = results.reduce((m, r) => Math.max(m, r.level), 0);
const icon = ["OK", "ADVERTENCIA", "CRÍTICO"];

const lines = [
  `## Salud de Bietix en ${net.name} — ${icon[worst]}`,
  "",
  `Revisado: ${new Date().toISOString()} · bloque ${await provider.getBlockNumber()}`,
  "",
  "| Estado | Chequeo | Detalle |",
  "| --- | --- | --- |",
  ...results.map((r) => `| ${icon[r.level]} | ${r.name} | ${r.detail} |`),
];
const report = lines.join("\n");
console.log(report);
if (process.env.GITHUB_STEP_SUMMARY) {
  const { appendFileSync } = await import("node:fs");
  appendFileSync(process.env.GITHUB_STEP_SUMMARY, report + "\n");
}
if (process.env.REPORT_FILE) {
  const { writeFileSync } = await import("node:fs");
  writeFileSync(process.env.REPORT_FILE, report + "\n");
}
process.exit(worst);
