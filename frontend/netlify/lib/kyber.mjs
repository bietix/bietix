// Lógica del intermediario con la API pública de KyberSwap (sin dependencias, probada con `node --test`).
//
// Por qué pasa por el servidor y no directo desde el navegador:
// - El sitio mantiene una CSP estricta: el navegador solo habla con bietix.com y con los nodos de Arbitrum.
// - El emisor y el receptor de los swaps (`sender` / `recipient`) los fija el servidor: siempre el Router de Bietix.
// - Se rechaza cualquier respuesta cuyo contrato de destino no sea el router de KyberSwap esperado.
// - Si más adelante se usa una clave de API, queda en el servidor y nunca llega al navegador.
// El contrato BietixRouter valida todo de nuevo on-chain (lista blanca, saldos y control contra oráculo):
// esto es una primera barrera, no la única.

export const CHAINS = {
  42161: {
    slug: "arbitrum",
    // MetaAggregationRouterV2 de KyberSwap (misma dirección en todas sus redes EVM)
    kyberRouter: "0x6131b5fae19ea4f9d964eac0408e4408b66337b5",
    stables: {
      "0xaf88d065e77c8cc2239327c5edb3a432268e5831": "USDC",
      "0xfd086bc7cd5c481dcc9c85ebe478a1c0b69fcbb9": "USDT",
    },
    assets: {
      "0x2f2a2543b76a4166549f7aab2e75bef0aefc5b0f": "WBTC",
      "0x82af49447d8a07e3bd95bd0d56f35241523fbab1": "WETH",
    },
  },
};

export const MAX_SLIPPAGE_BPS = 300; // el usuario elige 0,5%, 1% o 2% en la interfaz
const ADDRESS = /^0x[0-9a-f]{40}$/;
const AMOUNT = /^[1-9][0-9]{0,29}$/; // entero positivo, sin ceros a la izquierda, < 1e30
const HEXDATA = /^0x([0-9a-f]{2})+$/i;

export class BadRequest extends Error {
  constructor(msg, status = 400) {
    super(msg);
    this.status = status;
  }
}

const lower = (x) => (typeof x === "string" ? x.toLowerCase() : "");

function chainOf(chainId) {
  const c = CHAINS[Number(chainId)];
  if (!c) throw new BadRequest("Red no soportada");
  return c;
}

/** Solo se permiten swaps stable → WBTC/WETH (compra) o WBTC/WETH → stable (venta). */
export function checkPair(chain, tokenIn, tokenOut) {
  const a = lower(tokenIn), b = lower(tokenOut);
  if (!ADDRESS.test(a) || !ADDRESS.test(b)) throw new BadRequest("Token inválido");
  const buy = chain.stables[a] && chain.assets[b];
  const sell = chain.assets[a] && chain.stables[b];
  if (!buy && !sell) throw new BadRequest("Par no permitido");
  return [a, b];
}

function checkAmount(amountIn) {
  const s = String(amountIn);
  if (!AMOUNT.test(s)) throw new BadRequest("Monto inválido");
  return s;
}

export function routerFor(chainId, env) {
  const r = lower(env[`BIETIX_ROUTER_${Number(chainId)}`]);
  if (!ADDRESS.test(r)) throw new BadRequest("Bietix todavía no está desplegado en esta red", 503);
  return r;
}

function headers(env) {
  const h = { "content-type": "application/json", "x-client-id": env.KYBER_CLIENT_ID || "bietix" };
  if (env.KYBER_API_KEY) h["x-api-key"] = env.KYBER_API_KEY;
  return h;
}

async function call(fetchFn, url, init) {
  let res;
  try {
    res = await fetchFn(url, { ...init, signal: AbortSignal.timeout(8000) });
  } catch {
    throw new BadRequest("El agregador no respondió", 502);
  }
  let json = null;
  try {
    json = await res.json();
  } catch {
    /* respuesta no JSON */
  }
  if (!res.ok || !json || json.code !== 0 || !json.data) {
    throw new BadRequest(res.status === 429 ? "El agregador está saturado, probá en unos segundos" : "El agregador no encontró una ruta", 502);
  }
  return json.data;
}

/** Paso 1: cotización. Devuelve lo que se recibiría y la ruta para construir la transacción después. */
export async function quote({ chainId, tokenIn, tokenOut, amountIn }, env, fetchFn = fetch) {
  const chain = chainOf(chainId);
  const [a, b] = checkPair(chain, tokenIn, tokenOut);
  const amount = checkAmount(amountIn);
  const base = env.KYBER_BASE_URL || "https://aggregator-api.kyberswap.com";
  const qs = new URLSearchParams({ tokenIn: a, tokenOut: b, amountIn: amount });
  // Las cotizaciones RFQ (firmadas por market makers) no se pueden reproducir en un fork: se excluyen en pruebas.
  if (env.KYBER_EXCLUDE_RFQ === "true") qs.set("excludeRFQSources", "true");
  const data = await call(fetchFn, `${base}/${chain.slug}/api/v1/routes?${qs}`, { headers: headers(env) });

  const rs = data.routeSummary;
  if (lower(data.routerAddress) !== chain.kyberRouter) throw new BadRequest("Router del agregador inesperado", 502);
  if (!rs || lower(rs.tokenIn) !== a || lower(rs.tokenOut) !== b || String(rs.amountIn) !== amount) {
    throw new BadRequest("La ruta no coincide con lo pedido", 502);
  }
  if (!AMOUNT.test(String(rs.amountOut))) throw new BadRequest("La ruta no tiene salida", 502);
  return { amountOut: String(rs.amountOut), routeSummary: rs };
}

/** Paso 2: arma la transacción para que la ejecute el Router de Bietix (emisor y receptor = Router). */
export async function build({ chainId, routeSummary, slippageBps, origin }, env, fetchFn = fetch) {
  const chain = chainOf(chainId);
  const router = routerFor(chainId, env);
  if (!routeSummary || typeof routeSummary !== "object") throw new BadRequest("Falta la ruta");
  const [a, b] = checkPair(chain, routeSummary.tokenIn, routeSummary.tokenOut);
  const amount = checkAmount(routeSummary.amountIn);
  const slip = Number(slippageBps);
  if (!Number.isInteger(slip) || slip < 1 || slip > MAX_SLIPPAGE_BPS) throw new BadRequest("Tolerancia inválida");

  const body = {
    routeSummary,
    sender: router,
    recipient: router,
    slippageTolerance: slip,
    deadline: Math.floor(Date.now() / 1000) + 600,
    source: env.KYBER_CLIENT_ID || "bietix",
  };
  // `origin` = billetera del usuario: KyberSwap la usa para no limitar a un emisor fijo (nuestro Router).
  if (ADDRESS.test(lower(origin))) body.origin = lower(origin);

  const base = env.KYBER_BASE_URL || "https://aggregator-api.kyberswap.com";
  const data = await call(fetchFn, `${base}/${chain.slug}/api/v1/route/build`, {
    method: "POST",
    headers: headers(env),
    body: JSON.stringify(body),
  });

  if (lower(data.routerAddress) !== chain.kyberRouter) throw new BadRequest("Router del agregador inesperado", 502);
  if (String(data.amountIn) !== amount) throw new BadRequest("El monto armado no coincide", 502);
  if (data.transactionValue != null && !/^(0x)?0*$/i.test(String(data.transactionValue))) throw new BadRequest("La ruta pide ETH nativo", 502);
  if (!HEXDATA.test(String(data.data))) throw new BadRequest("Transacción vacía", 502);
  return {
    to: chain.kyberRouter,
    tokenIn: a,
    tokenOut: b,
    amountIn: amount,
    amountOut: String(data.amountOut),
    data: String(data.data),
  };
}
