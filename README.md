# DUOX — Índice BTC/ETH en Arbitrum

Token ERC-20 donde **1 DUOX = 0,0001 WBTC + 0,003 WETH** (valores de prueba; los definitivos se fijan al lanzar).
El precio del token es una fórmula de BTC y ETH, respaldada 1:1 por los activos reales que guarda el contrato.

> Estado: **Paso 4 de la hoja de ruta** — los tres contratos (`DuoxVault`, `OracleGuard`, `DuoxRouter`) programados y probados. Próximo: pruebas sobre fork de Arbitrum One.

## Qué hay en este repositorio

```
src/
  DuoxVault.sol                 Núcleo: token + custodia. Inmutable, sin oráculo, sin swaps.
  OracleGuard.sol               Red de seguridad de precios (Chainlink + sequencer de Arbitrum) para el Router.
  DuoxRouter.sol                Compra/venta con USDC/USDT vía agregadores en lista blanca. Reemplazable, sin fondos.
  interfaces/                   Interfaz de los feeds de Chainlink.
test/
  unit/DuoxVault.t.sol          39 pruebas unitarias (funciones, errores, permisos, ataques)
  unit/OracleGuard.t.sol        41 pruebas: precios inválidos, desactualizados, sequencer, depegs, márgenes, permisos
  unit/DuoxRouter.t.sol         44 pruebas: compra, venta, límites, pausas, ataques (agregador malicioso,
                                reentrada, donaciones), emergencias, permisos y 2 fuzz
  fuzz/DuoxVault.fuzz.t.sol     6 pruebas con valores aleatorios (1.000 casos cada una)
  invariant/                    6 invariantes con secuencias aleatorias (25.600 llamadas cada una)
  mocks/                        Tokens falsos: normal, con comisión de transferencia, reentrante
  utils/VaultTestBase.sol       Despliegue común para las pruebas
.github/workflows/test.yml      Integración continua (GitHub Actions)
```

## Herramientas necesarias

| Herramienta | Para qué | Instalación |
|---|---|---|
| **Git** | Control de versiones | https://git-scm.com |
| **Foundry** (forge, cast, anvil) | Compilar, probar, desplegar | `curl -L https://foundry.paradigm.xyz \| bash` y luego `foundryup` |
| **VS Code** + extensión *Solidity* (Juan Blanco o Nomic Foundation) | Editar el código | https://code.visualstudio.com |
| **Python 3** + **Slither** | Análisis estático de seguridad | `pip install slither-analyzer` |
| **Cuenta de GitHub** | Guardar el código y correr las pruebas automáticas | https://github.com |

Más adelante (pasos 5 a 8):

| Herramienta | Para qué |
|---|---|
| Proveedor de RPC (Alchemy, Infura o QuickNode; plan gratis) | Pruebas sobre fork de Arbitrum One y despliegue |
| Billetera (Rabby o MetaMask) + ETH de prueba en Arbitrum Sepolia (faucet) | Desplegar y probar en testnet |
| Cuenta en Arbiscan (API key gratis) | Verificar los contratos publicados |
| Safe (app.safe.global) + 3 hardware wallets | Multisig de administración (Fase 2) |

En Windows conviene usar **WSL** (Ubuntu dentro de Windows) para Foundry.

## Cómo correr las pruebas

```bash
git clone <tu-repo> duox && cd duox
git submodule update --init --recursive   # descarga OpenZeppelin y forge-std
forge build                               # compilar
forge test                                # todas las pruebas (~20 s)
forge test -vv --mc Invariant             # solo invariantes, con detalle de llamadas
forge coverage --no-match-coverage "test|mocks" --ir-minimum   # cobertura
FOUNDRY_PROFILE=ci forge test             # corrida larga (20.000 fuzz / 2.000 × 200 invariantes)
slither src/                              # análisis estático
```

Si el repositorio llegó como `.zip` (sin historial de git), las librerías ya están incluidas en `lib/`
y alcanza con `forge build && forge test`.

## Resultados actuales

- **131 pruebas pasan** (124 unitarias y fuzz + 6 invariantes del vault; tu versión de Foundry agrupa las invariantes en una sola línea).
- **Cobertura:** `DuoxVault` 100% líneas · `OracleGuard` 98,8% líneas, 100% ramas · `DuoxRouter` 100% líneas. Las ramas no cubiertas del Router son controles defensivos que no se pueden alcanzar con tokens estándar (por ejemplo, "el agregador tomó más de lo aprobado").
- **Slither:** 0 hallazgos. **Linter de Foundry:** 0 avisos (los falsos positivos están documentados línea por línea en el código).

### Invariantes que se verifican

| # | Regla | Estado |
|---|---|---|
| I1 | El vault siempre tiene ≥ el WBTC/WETH que exige el supply | ✅ |
| I2 | Todo holder puede redimir todo su saldo en cualquier estado (incluso con la acuñación pausada) | ✅ |
| I3 | Suma de saldos = supply total | ✅ |
| I6 | Acuñar y redimir nunca da ganancia (prueba fuzz) | ✅ |
| I7 | Ninguna acuñación supera el límite de supply | ✅ |
| I8 | Parámetros dentro de techos; nadie no autorizado los cambia | ✅ |
| I9 | Las unidades por token y los activos nunca cambian | ✅ |

Para el Router, I4 (no retiene fondos) e I5 (no deja aprobaciones abiertas) se verifican después de cada compra y venta en las pruebas unitarias y fuzz (`_assertRouterClean`).

## Decisiones de diseño aplicadas en el núcleo

- **Wrapper:** se pasa en el despliegue (recomendado WBTC). El código no depende de cuál sea.
- **Comisión In-Kind de acuñación:** 0,05% en las pruebas, ajustable por el Timelock hasta un techo fijo de 1%. Se cobra en los activos y va directo a tesorería.
- **Redención In-Kind:** sin comisión, sin mínimo y **no pausable**. La salida siempre está abierta.
- **Mínimo de acuñación:** 0,01 DUOX.
- **Comisiones de compra:** Router 0,25% + In-Kind del vault 0,05% = **0,30% total**. Venta: 0,30%.
- **Roles:** Timelock = administrador (cambios que suben riesgo) · Safe = despausar, revocar guardián, rescatar tokens ajenos · Guardián = pausar y bajar el límite. Nadie puede mover el colateral.

## Próximos pasos

5. Pruebas sobre fork de Arbitrum One (necesita un RPC).
