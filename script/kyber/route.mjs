// Pide una ruta real a KyberSwap con la misma lógica que usa el sitio (frontend/netlify/lib/kyber.mjs)
// y la imprime ABI-codificada como (address to, uint256 amountOut, bytes data) para `vm.ffi` en Foundry.
//
// Uso: node script/kyber/route.mjs <router> <tokenIn> <tokenOut> <amountIn> [slippageBps]
// Lo llama test/fork/KyberFork.t.sol; no hace falta correrlo a mano.
import { quote, build } from "../../frontend/netlify/lib/kyber.mjs";

const [router, tokenIn, tokenOut, amountIn, slippage = "100"] = process.argv.slice(2);
const env = { BIETIX_ROUTER_42161: router, KYBER_EXCLUDE_RFQ: "true", KYBER_CLIENT_ID: "bietix-fork-test" };

const q = await quote({ chainId: 42161, tokenIn, tokenOut, amountIn }, env);
const tx = await build({ chainId: 42161, routeSummary: q.routeSummary, slippageBps: Number(slippage) }, env);

const word = (hex) => hex.replace(/^0x/, "").padStart(64, "0");
const data = tx.data.replace(/^0x/, "");
const padded = data.padEnd(Math.ceil(data.length / 64) * 64, "0");
process.stdout.write(
  "0x" +
    word(tx.to) +
    word(BigInt(tx.amountOut).toString(16)) +
    word((96).toString(16)) + // offset de `data`
    word((data.length / 2).toString(16)) +
    padded,
);
