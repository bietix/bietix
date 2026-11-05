// Configuración por red. La página elige la red con ?chain=<id> (por defecto Arbitrum Sepolia).
// `swaps`: "dex" = DEX de prueba de testnet · "kyber" = KyberSwap a través de /api/swap (función de Netlify).
export const NETWORKS = {
  // Arbitrum One: las direcciones de Bietix se completan al desplegar en mainnet (hasta entonces, null).
  42161: {
    name: "Arbitrum One",
    testnet: false,
    swaps: "kyber",
    // RPC de Alchemy, app "bietix-web": la clave es pública a propósito y solo funciona desde bietix.com
    // (lista de dominios permitidos en el panel de Alchemy). Para scripts y pruebas se usa otra app, en el .env.
    rpc: "https://arb-mainnet.g.alchemy.com/v2/alch_W8NMrU7jmgDYmeiYLjlsB",
    explorer: "https://arbiscan.io",
    nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
    contracts: { vault: null, router: null, oracle: null, timelock: null },
    tokens: {
      USDC: { address: "0xaf88d065e77c8cC2239327C5EDb3A432268e5831", decimals: 6, permit: true }, // firma única
      USDT: { address: "0xFd086bC7CD5C481DCC9C85ebE478A1C0b69FCbb9", decimals: 6 },
      WBTC: { address: "0x2f2a2543B76A4166549F7aaB2e75Bef0aefC5B0f", decimals: 8 },
      WETH: { address: "0x82aF49447D8a07e3bd95BD0d56f35241523fBab1", decimals: 18 },
    },
  },
  // Arbitrum Sepolia, despliegue v2 (5 de noviembre de 2026): código final con nombre Bietix, GuardianCanceller,
  // firma única y KyberSwap. El despliegue v1 (DUOX) sigue en la red pero el sitio ya no lo usa (rama testnet-v1).
  421614: {
    name: "Arbitrum Sepolia",
    testnet: true,
    swaps: "dex",
    rpc: "https://sepolia-rollup.arbitrum.io/rpc",
    explorer: "https://sepolia.arbiscan.io",
    nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
    contracts: {
      vault: "0xBdf2095539DaE97d6487918c95f72c2B655C5Ca2",
      router: "0xf73A2CfF09C0625c6Bbea645320a87A96b90C2C0",
      oracle: "0x934b014e67f3a9d8893a038ba2134E3783B32c46",
      timelock: "0x6C62eA51D10d84b9F1dab1f3f0724F3918EfFE0C",
      canceller: "0xF48f813909f860f88175d98E5bD8A12D08B4bCfe",
      dex: "0x8cF1FDfF2541A12957Ca36a696eb9FB1bdAA2eB7",
    },
    tokens: {
      USDC: { address: "0xDda1fE23Dc0a8F563dC76AB3b2f6863d3Ed98c33", decimals: 6, permit: true }, // firma única
      USDT: { address: "0xd15c657E733aDB37b5A2980dF36816899C12A5Ae", decimals: 6 },
      WBTC: { address: "0x7aaDBE9361396BB6851173dD7BAbCA61c98362Aa", decimals: 8 },
      WETH: { address: "0xF40A9aA9A3B347EB82a585441d8b25c3A4495270", decimals: 18 },
    },
  },
  // Red local (anvil) para pruebas: las direcciones se completan con las del despliegue local.
  31337: {
    name: "Red local",
    testnet: true,
    swaps: "dex",
    rpc: "http://127.0.0.1:8545",
    explorer: "",
    nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
    contracts: {
      vault: "0xa85233C63b9Ee964Add6F2cffe00Fd84eb32338f",
      router: "0x4A679253410272dd5232B3Ff7cF5dbB88f295319",
      oracle: "0x322813Fd9A801c5507c9de605d63CEA4f2CE6c44",
      timelock: "0xc6e7DF5E7b4f2A278906862b61205850344D4e7d",
      dex: "0xB7f8BC63BbcaD18155201308C8f3540b07f84F5e",
    },
    tokens: {
      USDC: { address: "0x9fE46736679d2D9a65F0992F2272dE9f3c7fa6e0", decimals: 6 },
      USDT: { address: "0xCf7Ed3AccA5a467e9e704C703E8D87F634fB0Fc9", decimals: 6 },
      WBTC: { address: "0x5FbDB2315678afecb367f032d93F642f64180aa3", decimals: 8 },
      WETH: { address: "0xe7f1725E7734CE288F8367e1Bb143E90bb3F0512", decimals: 18 },
    },
  },
};

export const DEFAULT_CHAIN = 421614;
export const DEFAULT_SLIPPAGE_BPS = 100; // 1%
