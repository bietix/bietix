// Pruebas del intermediario con KyberSwap: `node --test frontend/netlify/lib/`
import { test } from "node:test";
import assert from "node:assert/strict";
import { quote, build, BadRequest } from "./kyber.mjs";

const USDC = "0xaf88d065e77c8cC2239327C5EDb3A432268e5831";
const WBTC = "0x2f2a2543B76A4166549F7aaB2e75Bef0aefC5B0f";
const WETH = "0x82aF49447D8a07e3bd95BD0d56f35241523fBab1";
const KYBER = "0x6131B5fae19EA4f9D964eAc0408E4408b66337b5";
const ROUTER = "0x1111111111111111111111111111111111111111";
const USER = "0x2222222222222222222222222222222222222222";
const env = { BIETIX_ROUTER_42161: ROUTER };

const summary = (o = {}) => ({ tokenIn: USDC.toLowerCase(), tokenOut: WBTC.toLowerCase(), amountIn: "500000000", amountOut: "714000", route: [], ...o });

/** Agregador falso: devuelve `data` y guarda lo que se le pidió. */
function fakeKyber(data, { status = 200, code = 0 } = {}) {
  const calls = [];
  const fn = async (url, init) => {
    calls.push({ url, init });
    return { ok: status === 200, status, json: async () => ({ code, data }) };
  };
  return { fn, calls };
}

const rejects = (p, re) => assert.rejects(p, (e) => e instanceof BadRequest && re.test(e.message));

// ─────────────────────────────── quote ───────────────────────────────

test("quote: cotiza una compra USDC → WBTC", async () => {
  const k = fakeKyber({ routerAddress: KYBER, routeSummary: summary() });
  const r = await quote({ chainId: 42161, tokenIn: USDC, tokenOut: WBTC, amountIn: "500000000" }, env, k.fn);
  assert.equal(r.amountOut, "714000");
  assert.match(k.calls[0].url, /^https:\/\/aggregator-api\.kyberswap\.com\/arbitrum\/api\/v1\/routes\?/);
  assert.equal(k.calls[0].init.headers["x-client-id"], "bietix");
});

test("quote: solo pares stable ↔ WBTC/WETH", async () => {
  const k = fakeKyber({});
  await rejects(quote({ chainId: 42161, tokenIn: USDC, tokenOut: USER, amountIn: "1" }, env, k.fn), /Par no permitido/);
  await rejects(quote({ chainId: 42161, tokenIn: WBTC, tokenOut: WETH, amountIn: "1" }, env, k.fn), /Par no permitido/);
  await rejects(quote({ chainId: 1, tokenIn: USDC, tokenOut: WBTC, amountIn: "1" }, env, k.fn), /Red no soportada/);
  assert.equal(k.calls.length, 0, "no se consulta al agregador si el pedido es inválido");
});

test("quote: montos inválidos", async () => {
  for (const amountIn of ["0", "-1", "1.5", "01", "1e6", "9".repeat(31), "", null]) {
    await rejects(quote({ chainId: 42161, tokenIn: USDC, tokenOut: WBTC, amountIn }, env, fakeKyber({}).fn), /Monto inválido/);
  }
});

test("quote: rechaza un router del agregador distinto al esperado", async () => {
  const k = fakeKyber({ routerAddress: USER, routeSummary: summary() });
  await rejects(quote({ chainId: 42161, tokenIn: USDC, tokenOut: WBTC, amountIn: "500000000" }, env, k.fn), /Router del agregador/);
});

test("quote: rechaza una ruta que no coincide con lo pedido", async () => {
  for (const bad of [summary({ tokenOut: WETH.toLowerCase() }), summary({ amountIn: "1" }), summary({ tokenIn: WBTC.toLowerCase() })]) {
    const k = fakeKyber({ routerAddress: KYBER, routeSummary: bad });
    await rejects(quote({ chainId: 42161, tokenIn: USDC, tokenOut: WBTC, amountIn: "500000000" }, env, k.fn), /no coincide/);
  }
});

test("quote: errores del agregador", async () => {
  await rejects(
    quote({ chainId: 42161, tokenIn: USDC, tokenOut: WBTC, amountIn: "1" }, env, fakeKyber({}, { status: 429 }).fn),
    /saturado/,
  );
  await rejects(
    quote({ chainId: 42161, tokenIn: USDC, tokenOut: WBTC, amountIn: "1" }, env, fakeKyber(null, { code: 4008 }).fn),
    /no encontró/,
  );
  const down = async () => { throw new Error("ECONNRESET"); };
  await rejects(quote({ chainId: 42161, tokenIn: USDC, tokenOut: WBTC, amountIn: "1" }, env, down), /no respondió/);
});

// ─────────────────────────────── build ───────────────────────────────

const okBuild = () => fakeKyber({ routerAddress: KYBER, amountIn: "500000000", amountOut: "714000", data: "0xabcdef", transactionValue: "0" });

test("build: emisor y receptor son siempre el Router de Bietix", async () => {
  const k = okBuild();
  const r = await build({ chainId: 42161, routeSummary: summary(), slippageBps: 100, origin: USER }, env, k.fn);
  assert.deepEqual(r, {
    to: KYBER.toLowerCase(), tokenIn: USDC.toLowerCase(), tokenOut: WBTC.toLowerCase(),
    amountIn: "500000000", amountOut: "714000", data: "0xabcdef",
  });
  const sent = JSON.parse(k.calls[0].init.body);
  assert.equal(sent.sender, ROUTER);
  assert.equal(sent.recipient, ROUTER);
  assert.equal(sent.origin, USER);
  assert.equal(sent.slippageTolerance, 100);
  assert.ok(sent.deadline > Date.now() / 1000);
});

test("build: el cliente no puede elegir otro receptor", async () => {
  const k = okBuild();
  await build({ chainId: 42161, routeSummary: summary(), slippageBps: 100, recipient: USER, sender: USER }, env, k.fn);
  const sent = JSON.parse(k.calls[0].init.body);
  assert.equal(sent.recipient, ROUTER);
  assert.equal(sent.sender, ROUTER);
});

test("build: sin Router desplegado responde 503", async () => {
  await assert.rejects(
    build({ chainId: 42161, routeSummary: summary(), slippageBps: 100 }, {}, okBuild().fn),
    (e) => e.status === 503,
  );
});

test("build: valida la ruta y la tolerancia", async () => {
  const k = okBuild();
  await rejects(build({ chainId: 42161, routeSummary: summary({ tokenOut: USER }), slippageBps: 100 }, env, k.fn), /Par no permitido/);
  for (const slippageBps of [0, 301, 1.5, "x"]) {
    await rejects(build({ chainId: 42161, routeSummary: summary(), slippageBps }, env, k.fn), /Tolerancia/);
  }
  await rejects(build({ chainId: 42161, slippageBps: 100 }, env, k.fn), /Falta la ruta/);
  assert.equal(k.calls.length, 0);
});

test("build: rechaza respuestas manipuladas del agregador", async () => {
  const cases = [
    [{ routerAddress: USER, amountIn: "500000000", data: "0xab" }, /Router del agregador/],
    [{ routerAddress: KYBER, amountIn: "1", data: "0xab" }, /no coincide/],
    [{ routerAddress: KYBER, amountIn: "500000000", data: "0xab", transactionValue: "1" }, /ETH nativo/],
    [{ routerAddress: KYBER, amountIn: "500000000", data: "0x" }, /vacía/],
  ];
  for (const [data, re] of cases) {
    await rejects(build({ chainId: 42161, routeSummary: summary(), slippageBps: 100 }, env, fakeKyber(data).fn), re);
  }
});

test("build: con clave de API la manda solo al agregador", async () => {
  const k = okBuild();
  await build({ chainId: 42161, routeSummary: summary(), slippageBps: 50 }, { ...env, KYBER_API_KEY: "secreta" }, k.fn);
  assert.equal(k.calls[0].init.headers["x-api-key"], "secreta");
});
