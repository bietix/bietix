// Chequeos de salud. Cada uno devuelve { name, level, detail } con level 0 = OK, 1 = advertencia, 2 = crítico.
// Separado de health.mjs para poder probarlo con contratos falsos (checks.test.mjs).

export const OK = 0;
export const WARN = 1;
export const CRIT = 2;

const VAULT = [
  "function totalSupply() view returns (uint256)",
  "function supplyCap() view returns (uint256)",
  "function UNIT_BTC() view returns (uint256)",
  "function UNIT_ETH() view returns (uint256)",
  "function mintPaused() view returns (bool)",
  "function defaultAdmin() view returns (address)",
  "function pendingDefaultAdmin() view returns (address,uint48)",
];
const ROUTER = [
  "function paused() view returns (bool)",
  "function buyPaused() view returns (bool)",
  "function sellPaused() view returns (bool)",
  "function sellLimitUsd() view returns (uint256)",
  "function sellCapacityUsd() view returns (uint256)",
  "function defaultAdmin() view returns (address)",
  "function pendingDefaultAdmin() view returns (address,uint48)",
];
const ORACLE = [
  "function indexPriceUsd(uint256,uint256) view returns (uint256)",
  "function wrapperAlert() view returns (bool)",
  "function defaultAdmin() view returns (address)",
  "function pendingDefaultAdmin() view returns (address,uint48)",
];
const ERC20 = ["function balanceOf(address) view returns (uint256)"];
const ZERO = "0x0000000000000000000000000000000000000000";

const check = async (name, fn) => {
  try {
    return { name, ...(await fn()) };
  } catch (e) {
    return { name, level: WARN, detail: `No se pudo leer: ${(e.shortMessage || e.message || String(e)).slice(0, 140)}` };
  }
};

export async function runChecks({ provider, net, Contract, formatUnits }) {
  const k = net.contracts;
  const vault = new Contract(k.vault, VAULT, provider);
  const router = new Contract(k.router, ROUTER, provider);
  const oracle = new Contract(k.oracle, ORACLE, provider);
  const wbtc = new Contract(net.tokens.WBTC.address, ERC20, provider);
  const weth = new Contract(net.tokens.WETH.address, ERC20, provider);
  const usd = (x, d = 0) => "$" + Number(formatUnits(x, 18)).toLocaleString("en-US", { maximumFractionDigits: d });

  const [supply, unitBtc, unitEth] = await Promise.all([vault.totalSupply(), vault.UNIT_BTC(), vault.UNIT_ETH()]);

  return Promise.all([
    // 1. Respaldo: la regla más importante del sistema (invariante I1).
    check("Respaldo 100%", async () => {
      const [b, e] = await Promise.all([wbtc.balanceOf(k.vault), weth.balanceOf(k.vault)]);
      const needB = (supply * unitBtc) / 10n ** 18n;
      const needE = (supply * unitEth) / 10n ** 18n;
      const ok = b >= needB && e >= needE;
      return {
        level: ok ? OK : CRIT,
        detail: `WBTC ${formatUnits(b, 8)} / ${formatUnits(needB, 8)} · WETH ${formatUnits(e, 18)} / ${formatUnits(needE, 18)}`,
      };
    }),

    // 2. Oráculos: si revierte, compras y ventas están frenadas (precio viejo, sequencer caído, fuera de rango).
    check("Oráculos", async () => {
      try {
        const p = await oracle.indexPriceUsd(unitBtc, unitEth);
        return { level: OK, detail: `Precio de 1 BIETIX: ${usd(p, 2)}` };
      } catch (e) {
        const reason = e.revert?.name || e.shortMessage || "revierte";
        return { level: WARN, detail: `No hay precio válido (${reason}): compras y ventas frenadas; el canje sigue abierto` };
      }
    }),

    check("Paridad WBTC/BTC", async () => {
      const alert = await oracle.wrapperAlert();
      return { level: alert ? WARN : OK, detail: alert ? "WBTC cotiza por debajo de 0,99 BTC" : "Normal" };
    }),

    // 3. Pausas: son una medida de seguridad; si hay alguna activa, alguien tiene que saber por qué.
    check("Pausas", async () => {
      const [p, pb, ps, pm] = await Promise.all([router.paused(), router.buyPaused(), router.sellPaused(), vault.mintPaused()]);
      const on = [p && "todo el Router", pb && "compras", ps && "ventas", pm && "acuñación"].filter(Boolean);
      return { level: on.length ? WARN : OK, detail: on.length ? `Pausado: ${on.join(", ")}` : "Ninguna" };
    }),

    // 4. Cupo de ventas de 24 h: casi agotado = mucha salida o un intento de bloquear a otros.
    check("Cupo de ventas 24 h", async () => {
      const [limit, cap] = await Promise.all([router.sellLimitUsd(), router.sellCapacityUsd()]);
      const low = limit > 0n && cap * 5n < limit; // menos del 20% disponible
      return { level: low ? WARN : OK, detail: `Disponible ${usd(cap)} de ${usd(limit)}` };
    }),

    check("Límite de emisión", async () => {
      const cap = await vault.supplyCap();
      const high = cap > 0n && supply * 10n > cap * 9n; // más del 90% usado
      return { level: high ? WARN : OK, detail: `${formatUnits(supply, 18)} BIETIX de ${formatUnits(cap, 18)}` };
    }),

    // 5. Gobierno: el administrador de los tres contratos tiene que ser el Timelock, sin cambios en curso.
    check("Administrador = Timelock", async () => {
      const issues = [];
      for (const [name, c] of [["Vault", vault], ["Router", router], ["Oráculo", oracle]]) {
        const [admin, [pending]] = await Promise.all([c.defaultAdmin(), c.pendingDefaultAdmin()]);
        if (admin.toLowerCase() !== k.timelock.toLowerCase()) issues.push(`${name}: admin ${admin}`);
        if (pending !== ZERO) issues.push(`${name}: transferencia de admin en curso a ${pending}`);
      }
      return { level: issues.length ? CRIT : OK, detail: issues.length ? issues.join(" · ") : "Correcto en Vault, Router y Oráculo" };
    }),
  ]);
}
