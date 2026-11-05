import {
  BrowserProvider, JsonRpcProvider, Contract, Interface, formatUnits, parseUnits, isError,
} from "./vendor/ethers.min.js";
import { NETWORKS, DEFAULT_CHAIN, DEFAULT_SLIPPAGE_BPS } from "./config.js";

// ═══════════════════════════════ ABIs mínimos ═══════════════════════════════
const ERC20 = [
  "function balanceOf(address) view returns (uint256)",
  "function allowance(address,address) view returns (uint256)",
  "function approve(address,uint256) returns (bool)",
  "function faucet()",
];
const VAULT = [
  ...ERC20,
  "function totalSupply() view returns (uint256)",
  "function UNIT_BTC() view returns (uint256)",
  "function UNIT_ETH() view returns (uint256)",
  "function mintPaused() view returns (bool)",
  "function previewRedeem(uint256) view returns (uint256,uint256)",
  "function redeemInKind(uint256,address) returns (uint256,uint256)",
];
const ROUTER = [
  "function buyFeeBps() view returns (uint256)",
  "function sellFeeBps() view returns (uint256)",
  "function paused() view returns (bool)",
  "function buyPaused() view returns (bool)",
  "function sellPaused() view returns (bool)",
  "function maxTradeUsd() view returns (uint256)",
  "function sharesFor(uint256,uint256) view returns (uint256)",
  "function buy(address,uint256,uint256,(address,address,uint256,bytes)[],uint256,address) returns (uint256)",
  "function sell(uint256,address,uint256,(address,address,uint256,bytes)[],uint256,address) returns (uint256)",
  "error IsPaused()", "error StableNotAllowed(address)", "error TargetNotAllowed(address)", "error InvalidStep()",
  "error Expired()", "error TradeTooLarge(uint256,uint256)", "error SellLimitExceeded(uint256,uint256)",
  "error InsufficientOutput(uint256,uint256)", "error SwapFailed(address)", "error BalanceMismatch(address)",
  "error ZeroAmount()",
];
const ORACLE = [
  "function indexPriceUsd(uint256,uint256) view returns (uint256)",
  "function basketValueUsd(uint256,uint256) view returns (uint256)",
  "function wrapperAlert() view returns (bool)",
  "function checkSequencer() view",
  "error SequencerDown()", "error GracePeriodNotOver()", "error StalePrice(bytes32)", "error WrapperDepegged()",
  "error StablePriceTooLow(address)", "error ExecutionWorseThanOracle(uint256,uint256)", "error PriceOutOfRange(bytes32)",
];
const DEX = [
  "function quote(address,uint256,address) view returns (uint256)",
  "function swap(address,uint256,address,uint256,address) returns (uint256)",
];
const VAULT_ERRORS = [
  "error MintIsPaused()", "error SupplyCapExceeded()", "error BelowMinimum()", "error FaucetCooldown()",
  "error ERC20InsufficientBalance(address,uint256,uint256)", "error ERC20InsufficientAllowance(address,uint256,uint256)",
];

// Mensajes claros para cada error de los contratos
const ERROR_TEXT = {
  IsPaused: "Las operaciones están pausadas por seguridad. Podés canjear tus BIETIX por BTC y ETH en la pestaña de canje.",
  MintIsPaused: "La creación de BIETIX está pausada por seguridad. El canje por BTC y ETH sigue disponible.",
  WrapperDepegged: "Las compras están pausadas: el WBTC perdió su paridad con BTC. Vender y canjear siguen disponibles.",
  StablePriceTooLow: "Esa stablecoin está por debajo de $0,98 y no se acepta en este momento. Probá con la otra.",
  SequencerDown: "La red Arbitrum está con problemas y las operaciones se detuvieron. El canje directo sigue disponible.",
  GracePeriodNotOver: "La red Arbitrum se acaba de recuperar. Esperá unos minutos para operar.",
  StalePrice: "Los precios de referencia están desactualizados. La operación se detuvo para protegerte.",
  PriceOutOfRange: "El precio de referencia es anómalo. La operación se detuvo para protegerte.",
  ExecutionWorseThanOracle: "El precio de mercado se alejó demasiado del de referencia. Probá de nuevo en unos minutos.",
  InsufficientOutput: "El precio cambió y recibirías menos que el mínimo. Probá de nuevo o subí la tolerancia.",
  TradeTooLarge: "El monto supera el máximo por operación ($25.000). Dividilo en varias operaciones.",
  SellLimitExceeded: "Se alcanzó el límite de ventas de 24 h. El cupo se recupera de a poco durante el día; mientras tanto podés canjear por BTC y ETH.",
  SupplyCapExceeded: "Se alcanzó el límite de BIETIX en circulación de esta etapa.",
  BelowMinimum: "El monto es menor al mínimo (0,01 BIETIX).",
  FaucetCooldown: "Ya pediste tokens de prueba hace menos de una hora.",
  Expired: "La operación tardó demasiado y venció. Probá de nuevo.",
  ERC20InsufficientBalance: "No tenés saldo suficiente para ese monto.",
  ERC20InsufficientAllowance: "Falta la autorización para usar tus tokens. Probá de nuevo y aceptá el primer paso en tu billetera.",
};

// ═══════════════════════════════ Estado ═══════════════════════════════
const params = new URLSearchParams(location.search);
const chainId = Number(params.get("chain") || DEFAULT_CHAIN);
const net = NETWORKS[chainId];
const readProvider = new JsonRpcProvider(net.rpc, chainId, { staticNetwork: true });
const errorIface = new Interface([...ROUTER, ...ORACLE, ...VAULT_ERRORS].filter((f) => f.startsWith("error")));

let signer = null;
let account = null;
let slippageBps = DEFAULT_SLIPPAGE_BPS;
const st = { unitBtc: 0n, unitEth: 0n, buyFee: 30n, sellFee: 30n, price: 0n, bal: { USDC: 0n, USDT: 0n, BIETIX: 0n }, eth: 0n };

const c = (addr, abi, runner = readProvider) => new Contract(addr, abi, runner);
const $ = (id) => document.getElementById(id);
const tokens = net.tokens;

// ═══════════════════════════════ Formato ═══════════════════════════════
const nf = (min, max) => new Intl.NumberFormat("es-AR", { minimumFractionDigits: min, maximumFractionDigits: max });
const usd = (v18) => "$ " + nf(2, 2).format(Number(formatUnits(v18, 18)));
const amt = (v, dec, max = 6) => nf(0, max).format(Number(formatUnits(v, dec)));
const parseInput = (s, dec) => {
  const clean = (s || "").trim().replace(/\./g, "").replace(",", ".");
  if (!clean || isNaN(Number(clean)) || Number(clean) <= 0) return 0n;
  try { return parseUnits(clean, dec); } catch { return 0n; }
};
const ceilFee = (x, bps) => (x * bps + 9999n) / 10000n;
const withSlip = (x) => (x * BigInt(10000 - slippageBps)) / 10000n;

// ═══════════════════════════════ Lectura del estado ═══════════════════════════════
async function loadStats() {
  const vault = c(net.contracts.vault, VAULT);
  const router = c(net.contracts.router, ROUTER);
  const oracle = c(net.contracts.oracle, ORACLE);
  const wbtc = c(tokens.WBTC.address, ERC20);
  const weth = c(tokens.WETH.address, ERC20);

  const [unitBtc, unitEth, supply, vBtc, vEth, buyFee, sellFee, paused, buyPaused, sellPaused, mintPaused] =
    await Promise.all([
      vault.UNIT_BTC(), vault.UNIT_ETH(), vault.totalSupply(), wbtc.balanceOf(net.contracts.vault),
      weth.balanceOf(net.contracts.vault), router.buyFeeBps(), router.sellFeeBps(), router.paused(),
      router.buyPaused(), router.sellPaused(), vault.mintPaused(),
    ]);
  Object.assign(st, { unitBtc, unitEth, buyFee, sellFee });

  $("unit-btc").textContent = amt(unitBtc, 8, 8);
  $("unit-eth").textContent = amt(unitEth, 18, 5);

  const needBtc = (supply * unitBtc) / 10n ** 18n;
  const needEth = (supply * unitEth) / 10n ** 18n;
  $("vault-btc").textContent = amt(vBtc, 8, 8);
  $("vault-eth").textContent = amt(vEth, 18, 6);
  $("need-btc").textContent = amt(needBtc, 8, 8);
  $("need-eth").textContent = amt(needEth, 18, 6);
  $("supply").textContent = amt(supply, 18, 2);

  const ok = vBtc >= needBtc && vEth >= needEth;
  const verdict = $("backing-verdict");
  verdict.textContent = ok
    ? "Cada BIETIX está respaldado al 100%."
    : "Atención: el respaldo no coincide con lo esperado.";
  verdict.className = "backing-verdict " + (ok ? "is-ok" : "is-error");

  // Precios (si el oráculo falla, se avisa y se sigue mostrando lo demás)
  const banners = [];
  try {
    const price = await oracle.indexPriceUsd(unitBtc, unitEth);
    st.price = price;
    $("price-usd").textContent = usd(price);
    const btcUsd = await oracle.basketValueUsd(unitBtc, 0n);
    const pctBtc = Number((btcUsd * 1000n) / price) / 10;
    setMix(pctBtc);
    $("tvl").textContent = usd((price * supply) / 10n ** 18n);
    if (await oracle.wrapperAlert()) banners.push(["WBTC está cotizando por debajo de BTC. Estamos atentos.", false]);
  } catch (e) {
    banners.push([explain(e) || "Los precios de referencia no están disponibles ahora.", true]);
  }
  if (paused) banners.push(["Compras y ventas pausadas por seguridad. El canje por BTC y ETH sigue disponible.", true]);
  else if (buyPaused || mintPaused) banners.push(["Las compras están pausadas por seguridad. Vender y canjear siguen disponibles.", true]);
  else if (sellPaused) banners.push(["Las ventas por stablecoins están pausadas. El canje por BTC y ETH sigue disponible.", true]);
  showBanner(banners);
}

function setMix(pctBtc) {
  const b = Math.max(0, Math.min(100, pctBtc));
  $("mix-btc").style.width = b + "%";
  $("mix-eth").style.width = 100 - b + "%";
  $("pct-btc").textContent = nf(0, 1).format(b) + "%";
  $("pct-eth").textContent = nf(0, 1).format(100 - b) + "%";
  $("mix-bar").setAttribute("aria-label", `Bitcoin ${nf(0, 1).format(b)}%, Ether ${nf(0, 1).format(100 - b)}%`);
}

function showBanner(list) {
  const el = $("banner");
  if (!list.length) { el.hidden = true; return; }
  el.hidden = false;
  el.textContent = list.map((x) => x[0]).join(" ");
  el.className = "banner" + (list.some((x) => x[1]) ? " is-danger" : "");
}

async function loadBalances() {
  if (!account) return;
  const stable = $("buy-stable").value;
  const [usdcBal, usdtBal, own, eth] = await Promise.all([
    c(tokens.USDC.address, ERC20).balanceOf(account),
    c(tokens.USDT.address, ERC20).balanceOf(account),
    c(net.contracts.vault, VAULT).balanceOf(account),
    readProvider.getBalance(account),
  ]);
  st.bal = { USDC: usdcBal, USDT: usdtBal, BIETIX: own };
  st.eth = eth;
  const bal = st.bal[stable];
  $("buy-balance").textContent = `Saldo: ${amt(bal, tokens[stable].decimals, 2)} ${stable}`;
  $("sell-balance").textContent = `Saldo: ${amt(own, 18, 4)} BIETIX`;
  $("exit-balance").textContent = `Saldo: ${amt(own, 18, 4)} BIETIX`;
  $("sell-max").dataset.max = formatUnits(own, 18);
  $("exit-max").dataset.max = formatUnits(own, 18);
  if (eth === 0n) status("Tu billetera no tiene ETH para pagar el gas de la red. Conseguí ETH de prueba en una faucet de Arbitrum Sepolia.", "error");
  updateButtons();
}

// ═══════════════════════════════ Cotizaciones ═══════════════════════════════
// En testnet los swaps van por el DEX de prueba. En mainnet este módulo usa la API de un agregador.
const swaps = {
  async quote(tokenIn, amountIn, tokenOut) {
    return c(net.contracts.dex, DEX).quote(tokenIn, amountIn, tokenOut);
  },
  step(tokenIn, amountIn, tokenOut, minOut) {
    const data = new Interface(DEX).encodeFunctionData("swap", [tokenIn, amountIn, tokenOut, minOut, net.contracts.router]);
    return [net.contracts.dex, tokenIn, amountIn, data];
  },
};

async function quoteBuy() {
  const stable = $("buy-stable").value;
  const amountIn = parseInput($("buy-amount").value, tokens[stable].decimals);
  if (amountIn === 0n) { resetQuote("buy"); return null; }
  const fee = ceilFee(amountIn, st.buyFee);
  const net_ = amountIn - fee;
  const half = net_ / 2n;
  const [qb, qe] = await Promise.all([
    swaps.quote(tokens[stable].address, half, tokens.WBTC.address),
    swaps.quote(tokens[stable].address, net_ - half, tokens.WETH.address),
  ]);
  const shares = await c(net.contracts.router, ROUTER).sharesFor(qb, qe);
  const minShares = withSlip(shares);
  $("buy-out").textContent = amt(shares, 18, 4);
  $("buy-out-usd").textContent = st.price ? "≈ " + usd((shares * st.price) / 10n ** 18n) : "";
  // comisión total = Router + In-Kind del vault (0,05%)
  const totalFee = fee + ceilFee(net_, 5n);
  $("buy-fee").textContent = `${amt(totalFee, tokens[stable].decimals, 2)} ${stable}`;
  $("buy-min").textContent = `${amt(minShares, 18, 4)} BIETIX`;
  return { stable, amountIn, half, net: net_, qb, qe, minShares };
}

async function quoteSell() {
  const stable = $("sell-stable").value;
  $("sell-out-unit").textContent = stable;
  const shares = parseInput($("sell-amount").value, 18);
  if (shares === 0n) { resetQuote("sell"); return null; }
  const [b, e] = await c(net.contracts.vault, VAULT).previewRedeem(shares);
  const [qb, qe] = await Promise.all([
    b > 0n ? swaps.quote(tokens.WBTC.address, b, tokens[stable].address) : 0n,
    e > 0n ? swaps.quote(tokens.WETH.address, e, tokens[stable].address) : 0n,
  ]);
  const gross = qb + qe;
  const fee = ceilFee(gross, st.sellFee);
  const out = gross - fee;
  const minOut = withSlip(out);
  const d = tokens[stable].decimals;
  $("sell-out").textContent = amt(out, d, 2);
  $("sell-fee").textContent = `${amt(fee, d, 2)} ${stable}`;
  $("sell-min").textContent = `${amt(minOut, d, 2)} ${stable}`;
  return { stable, shares, b, e, qb, qe, minOut };
}

async function quoteExit() {
  const shares = parseInput($("exit-amount").value, 18);
  if (shares === 0n) { $("exit-btc").textContent = "—"; $("exit-eth").textContent = "—"; return null; }
  const [b, e] = await c(net.contracts.vault, VAULT).previewRedeem(shares);
  $("exit-btc").textContent = amt(b, 8, 8);
  $("exit-eth").textContent = amt(e, 18, 6);
  return { shares };
}

function resetQuote(kind) {
  if (kind === "buy") {
    $("buy-out").textContent = "0"; $("buy-out-usd").textContent = ""; $("buy-fee").textContent = "—"; $("buy-min").textContent = "—";
  } else {
    $("sell-out").textContent = "0"; $("sell-fee").textContent = "—"; $("sell-min").textContent = "—";
  }
}

// ═══════════════════════════════ Operaciones ═══════════════════════════════
async function ensureAllowance(tokenAddr, spender, amount, label) {
  const t = c(tokenAddr, ERC20, signer);
  const current = await t.allowance(account, spender);
  if (current >= amount) return;
  status(`Paso 1 de 2: autorizá a BIETIX a usar tus ${label} en tu billetera…`);
  if (current > 0n) await (await t.approve(spender, 0n, await gasOverrides())).wait(); // tokens tipo USDT
  await (await t.approve(spender, amount, await gasOverrides())).wait();
}

async function doBuy(ev) {
  ev.preventDefault();
  const q = await quoteBuy();
  if (!q) return;
  await run("buy-btn", async () => {
    await ensureAllowance(tokens[q.stable].address, net.contracts.router, q.amountIn, q.stable);
    const steps = [
      swaps.step(tokens[q.stable].address, q.half, tokens.WBTC.address, withSlip(q.qb)),
      swaps.step(tokens[q.stable].address, q.net - q.half, tokens.WETH.address, withSlip(q.qe)),
    ];
    status("Confirmá la compra en tu billetera…");
    const router = c(net.contracts.router, ROUTER, signer);
    const tx = await router.buy(tokens[q.stable].address, q.amountIn, q.minShares, steps, deadline(), account, await gasOverrides());
    status("Comprando…");
    await tx.wait();
    $("buy-amount").value = "";
    resetQuote("buy");
    return ["Compra completada.", tx.hash];
  });
}

async function doSell(ev) {
  ev.preventDefault();
  const q = await quoteSell();
  if (!q) return;
  await run("sell-btn", async () => {
    await ensureAllowance(net.contracts.vault, net.contracts.router, q.shares, "BIETIX");
    const steps = [];
    if (q.b > 0n) steps.push(swaps.step(tokens.WBTC.address, q.b, tokens[q.stable].address, withSlip(q.qb)));
    if (q.e > 0n) steps.push(swaps.step(tokens.WETH.address, q.e, tokens[q.stable].address, withSlip(q.qe)));
    status("Confirmá la venta en tu billetera…");
    const router = c(net.contracts.router, ROUTER, signer);
    const tx = await router.sell(q.shares, tokens[q.stable].address, q.minOut, steps, deadline(), account, await gasOverrides());
    status("Vendiendo…");
    await tx.wait();
    $("sell-amount").value = "";
    resetQuote("sell");
    return ["Venta completada.", tx.hash];
  });
}

async function doExit(ev) {
  ev.preventDefault();
  const q = await quoteExit();
  if (!q) return;
  await run("exit-btn", async () => {
    status("Confirmá el canje en tu billetera…");
    const tx = await c(net.contracts.vault, VAULT, signer).redeemInKind(q.shares, account, await gasOverrides());
    status("Canjeando…");
    await tx.wait();
    $("exit-amount").value = "";
    return ["Canje completado. El WBTC y el WETH ya están en tu billetera.", tx.hash];
  });
}

async function doFaucet(symbol, btn) {
  await run(null, async () => {
    status(`Confirmá en tu billetera para recibir ${symbol} de prueba…`);
    const tx = await c(tokens[symbol].address, ERC20, signer).faucet(await gasOverrides());
    await tx.wait();
    return [`Listo: recibiste ${symbol} de prueba.`, tx.hash];
  }, btn);
}

async function run(btnId, fn, btnEl) {
  const btn = btnEl || (btnId && $(btnId));
  if (btn) btn.disabled = true;
  try {
    const [msg, hash] = await fn();
    status(msg, "ok", hash);
    await Promise.all([loadStats(), loadBalances()]);
  } catch (e) {
    console.error(e);
    status(explain(e) || "La operación no se pudo completar.", "error");
  } finally {
    if (btn) btn.disabled = false;
    updateButtons();
  }
}

const deadline = () => Math.floor(Date.now() / 1000) + 600;

// MetaMask propone en Arbitrum un tope de gas igual a la tarifa base del momento; si la red sube apenas,
// la transacción se rechaza ("max fee per gas less than block base fee"). Se sugiere un tope con margen
// (el doble de la tarifa base). En Arbitrum solo se cobra la tarifa real: el margen no se paga.
async function gasOverrides() {
  try {
    const block = await readProvider.getBlock("latest");
    const base = block?.baseFeePerGas ?? 0n;
    if (base === 0n) return {};
    return { maxFeePerGas: base * 2n, maxPriorityFeePerGas: 0n };
  } catch {
    return {};
  }
}

function explain(e) {
  if (isError(e, "ACTION_REJECTED")) return "Cancelaste la operación en tu billetera.";
  // Las billeteras anidan los datos del error de formas distintas: se busca cualquier "0x…" con selector.
  for (const data of findRevertData(e)) {
    try {
      const parsed = errorIface.parseError(data);
      if (parsed && ERROR_TEXT[parsed.name]) return ERROR_TEXT[parsed.name];
    } catch { /* no es un error conocido */ }
  }
  const name = e?.revert?.name;
  if (name && ERROR_TEXT[name]) return ERROR_TEXT[name];
  const msg = JSON.stringify(e?.error || e?.info || e?.message || "");
  if (/insufficient funds/i.test(msg) || /insufficient funds/i.test(e?.message || "")) return "No tenés ETH suficiente para pagar el gas de la red.";
  if (/less than block base fee/i.test(msg) || /less than block base fee/i.test(e?.message || "")) {
    return "La tarifa de la red subió mientras firmabas. Probá de nuevo: no se cobró nada.";
  }
  return null;
}

function findRevertData(e, out = [], depth = 0) {
  if (!e || depth > 6) return out;
  if (typeof e === "string") {
    if (/^0x[0-9a-fA-F]{8}/.test(e)) out.push(e);
    return out;
  }
  if (typeof e === "object") {
    for (const k of ["data", "error", "info", "cause", "originalError", "value"]) {
      if (k in e) findRevertData(e[k], out, depth + 1);
    }
  }
  return out;
}

function status(msg, kind = "", hash) {
  const el = $("tx-status");
  el.className = "tx-status" + (kind ? " is-" + kind : "");
  el.textContent = msg + " ";
  if (hash && net.explorer) {
    const a = document.createElement("a");
    a.href = `${net.explorer}/tx/${hash}`;
    a.target = "_blank";
    a.rel = "noopener";
    a.textContent = "Ver la transacción";
    el.appendChild(a);
  }
}

// ═══════════════════════════════ Billetera ═══════════════════════════════
async function connect() {
  if (!window.ethereum) {
    status("Instalá MetaMask (o una billetera compatible) para operar.", "error");
    return;
  }
  try {
    await window.ethereum.request({ method: "eth_requestAccounts" });
    await switchChain();
    const provider = new BrowserProvider(window.ethereum);
    signer = await provider.getSigner();
    account = await signer.getAddress();
    $("connect").textContent = account.slice(0, 6) + "…" + account.slice(-4);
    $("faucet").hidden = !net.testnet;
    status("");
    await loadBalances();
  } catch (e) {
    console.error(e);
    status(explain(e) || "No se pudo conectar la billetera.", "error");
  }
  updateButtons();
}

async function switchChain() {
  const hex = "0x" + chainId.toString(16);
  try {
    await window.ethereum.request({ method: "wallet_switchEthereumChain", params: [{ chainId: hex }] });
  } catch (e) {
    if (e.code === 4902) {
      await window.ethereum.request({
        method: "wallet_addEthereumChain",
        params: [{ chainId: hex, chainName: net.name, rpcUrls: [net.rpc], nativeCurrency: net.nativeCurrency, blockExplorerUrls: net.explorer ? [net.explorer] : [] }],
      });
    } else throw e;
  }
}

function updateButtons() {
  const label = { "buy-btn": "Comprar BIETIX", "sell-btn": "Vender BIETIX", "exit-btn": "Canjear por BTC y ETH" };
  for (const [id, text] of Object.entries(label)) {
    const b = $(id);
    if (!account) { b.disabled = true; b.textContent = "Conectá tu billetera"; continue; }
    const input = { "buy-btn": "buy-amount", "sell-btn": "sell-amount", "exit-btn": "exit-amount" }[id];
    const isBuy = id === "buy-btn";
    const stable = $("buy-stable").value;
    const value = parseInput($(input).value, isBuy ? tokens[stable].decimals : 18);
    const balance = isBuy ? st.bal[stable] : st.bal.BIETIX;
    if (value === 0n) { b.disabled = true; b.textContent = "Ingresá un monto"; continue; }
    if (value > balance) {
      b.disabled = true;
      b.textContent = isBuy ? `No tenés suficiente ${stable}` : "No tenés suficientes BIETIX";
      continue;
    }
    b.disabled = false;
    b.textContent = text;
  }
}

// ═══════════════════════════════ Interacción ═══════════════════════════════
function debounce(fn, ms = 300) {
  let t;
  return (...a) => { clearTimeout(t); t = setTimeout(() => fn(...a).catch((e) => console.error(e)), ms); };
}

function initTabs() {
  const tabs = ["buy", "sell", "exit"];
  tabs.forEach((name, i) => {
    const tab = $("tab-" + name);
    tab.addEventListener("click", () => select(name));
    tab.addEventListener("keydown", (e) => {
      if (e.key === "ArrowRight" || e.key === "ArrowLeft") {
        const next = tabs[(i + (e.key === "ArrowRight" ? 1 : tabs.length - 1)) % tabs.length];
        select(next);
        $("tab-" + next).focus();
      }
    });
  });
  function select(name) {
    for (const n of tabs) {
      const on = n === name;
      $("tab-" + n).setAttribute("aria-selected", on);
      $("tab-" + n).tabIndex = on ? 0 : -1;
      $("panel-" + n).hidden = !on;
    }
    status("");
  }
}

function init() {
  $("net-pill").hidden = false;
  $("net-pill").textContent = net.name;
  $("footer-net").textContent = net.testnet
    ? `Red: ${net.name} (prueba). Los tokens de esta red no tienen valor.`
    : `Red: ${net.name}.`;
  const links = [["Vault (BIETIX)", net.contracts.vault], ["Router", net.contracts.router], ["Oráculo", net.contracts.oracle], ["Timelock", net.contracts.timelock]];
  $("footer-contracts").innerHTML = "";
  links.forEach(([name, addr], i) => {
    const a = document.createElement(net.explorer ? "a" : "span");
    if (net.explorer) { a.href = `${net.explorer}/address/${addr}`; a.target = "_blank"; a.rel = "noopener"; }
    a.textContent = `${name} ${addr.slice(0, 6)}…${addr.slice(-4)}`;
    $("footer-contracts").appendChild(a);
    if (i < links.length - 1) $("footer-contracts").append(", ");
  });
  if (net.explorer) $("vault-link").href = `${net.explorer}/address/${net.contracts.vault}`;
  else $("vault-link").hidden = true;

  initTabs();
  $("connect").addEventListener("click", connect);
  $("panel-buy").addEventListener("submit", doBuy);
  $("panel-sell").addEventListener("submit", doSell);
  $("panel-exit").addEventListener("submit", doExit);

  const qb = debounce(quoteBuy), qs = debounce(quoteSell), qe = debounce(quoteExit);
  $("buy-amount").addEventListener("input", () => { updateButtons(); qb(); });
  $("buy-stable").addEventListener("change", () => { updateButtons(); qb(); loadBalances(); });
  $("sell-amount").addEventListener("input", () => { updateButtons(); qs(); });
  $("sell-stable").addEventListener("change", () => qs());
  $("exit-amount").addEventListener("input", () => { updateButtons(); qe(); });
  $("buy-max").addEventListener("click", () => {
    const stable = $("buy-stable").value;
    $("buy-amount").value = formatUnits(st.bal[stable], tokens[stable].decimals).replace(".", ",");
    updateButtons(); qb();
  });
  $("sell-max").addEventListener("click", () => { $("sell-amount").value = ($("sell-max").dataset.max || "0").replace(".", ","); updateButtons(); qs(); });
  $("exit-max").addEventListener("click", () => { $("exit-amount").value = ($("exit-max").dataset.max || "0").replace(".", ","); updateButtons(); qe(); });
  document.querySelectorAll("[data-faucet]").forEach((b) => b.addEventListener("click", () => doFaucet(b.dataset.faucet, b)));
  document.querySelectorAll("[data-slip]").forEach((b) => b.addEventListener("click", () => {
    slippageBps = Number(b.dataset.slip);
    document.querySelectorAll("[data-slip]").forEach((x) => x.setAttribute("aria-checked", x === b));
    $("slip-label").textContent = b.textContent;
    qb(); qs();
  }));

  if (window.ethereum) {
    window.ethereum.on?.("accountsChanged", () => location.reload());
    window.ethereum.on?.("chainChanged", () => location.reload());
  }
  updateButtons();
  loadStats().catch((e) => { console.error(e); showBanner([["No se pudo leer el contrato. Revisá tu conexión.", true]]); });
  setInterval(() => loadStats().catch(() => {}), 30000);
}

init();
