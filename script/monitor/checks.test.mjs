// Pruebas de los chequeos con contratos falsos: `node --test script/monitor/*.test.mjs`
import { test } from "node:test";
import assert from "node:assert/strict";
import { formatUnits } from "../../frontend/vendor/ethers.min.js";
import { runChecks, OK, WARN, CRIT } from "./checks.mjs";

const A = { vault: "0xv", router: "0xr", oracle: "0xo", timelock: "0xT", wbtc: "0xb", weth: "0xe" };
const ZERO = "0x0000000000000000000000000000000000000000";
const net = { contracts: { vault: A.vault, router: A.router, oracle: A.oracle, timelock: A.timelock }, tokens: { WBTC: { address: A.wbtc }, WETH: { address: A.weth } } };

/** Estado sano: 100 BIETIX respaldados, sin pausas, admin = Timelock. `over` pisa cualquier valor. */
function world(over = {}) {
  const s = {
    supply: 100n * 10n ** 18n, unitBtc: 10_000n, unitEth: 3n * 10n ** 15n, cap: 1_000_000n * 10n ** 18n,
    vBtc: 1_000_000n, vEth: 3n * 10n ** 17n, price: 155n * 10n ** 17n, alert: false,
    paused: false, buyPaused: false, sellPaused: false, mintPaused: false,
    sellLimit: 50_000n * 10n ** 18n, sellCap: 50_000n * 10n ** 18n, admin: A.timelock, pending: ZERO, oracleFails: false,
    ...over,
  };
  const common = { defaultAdmin: async () => s.admin, pendingDefaultAdmin: async () => [s.pending, 0] };
  const by = {
    [A.vault]: { ...common, totalSupply: async () => s.supply, supplyCap: async () => s.cap, UNIT_BTC: async () => s.unitBtc, UNIT_ETH: async () => s.unitEth, mintPaused: async () => s.mintPaused },
    [A.router]: { ...common, paused: async () => s.paused, buyPaused: async () => s.buyPaused, sellPaused: async () => s.sellPaused, sellLimitUsd: async () => s.sellLimit, sellCapacityUsd: async () => s.sellCap },
    [A.oracle]: { ...common, wrapperAlert: async () => s.alert, indexPriceUsd: async () => { if (s.oracleFails) { const e = new Error("revert"); e.revert = { name: "StalePrice" }; throw e; } return s.price; } },
    [A.wbtc]: { balanceOf: async () => s.vBtc },
    [A.weth]: { balanceOf: async () => s.vEth },
  };
  return function Contract(addr) { return by[addr]; };
}

const levels = async (over) => {
  const r = await runChecks({ provider: {}, net, Contract: world(over), formatUnits });
  return Object.fromEntries(r.map((x) => [x.name, x.level]));
};

test("estado sano: todo OK", async () => {
  const l = await levels();
  assert.ok(Object.values(l).every((v) => v === OK), JSON.stringify(l));
});

test("falta colateral: crítico", async () => {
  assert.equal((await levels({ vBtc: 999_999n }))["Respaldo 100%"], CRIT);
  assert.equal((await levels({ vEth: 1n }))["Respaldo 100%"], CRIT);
});

test("oráculo sin precio válido: advertencia", async () => {
  assert.equal((await levels({ oracleFails: true }))["Oráculos"], WARN);
});

test("pausas, depeg, cupo y emisión: advertencias", async () => {
  assert.equal((await levels({ sellPaused: true }))["Pausas"], WARN);
  assert.equal((await levels({ alert: true }))["Paridad WBTC/BTC"], WARN);
  assert.equal((await levels({ sellCap: 9_000n * 10n ** 18n }))["Cupo de ventas 24 h"], WARN);
  assert.equal((await levels({ cap: 105n * 10n ** 18n }))["Límite de emisión"], WARN);
});

test("cambio de administrador: crítico", async () => {
  assert.equal((await levels({ admin: "0xATACANTE" }))["Administrador = Timelock"], CRIT);
  assert.equal((await levels({ pending: "0x1111111111111111111111111111111111111111" }))["Administrador = Timelock"], CRIT);
});
