# Pre-auditoría propia de Bietix

*5 de noviembre de 2026 · contratos en `src/` · Solidity 0.8.38*

Antes de una auditoría externa se revisan los cuatro puntos que los auditores miran primero: calidad del código, cobertura de pruebas, análisis estático y los riesgos típicos de un token. **Resultado: todo en verde.**

| Área | Resultado |
| --- | --- |
| Estilo (forge fmt, forge lint, Solhint) | 0 errores, 0 avisos |
| NatSpec | 100% de contratos, funciones, eventos, errores, structs y variables públicas |
| Código muerto | Ninguno (se eliminó una comprobación imposible en `_sharesFor`) |
| Versión del compilador | Fija: `pragma solidity 0.8.38;` en todos los archivos |
| Cobertura de `src/` | **100%** de líneas, sentencias, ramas y funciones |
| Pruebas | 182 pasan, 0 fallan (12 omitidas: fork, necesitan RPC) |
| Slither | 0 resultados |
| Aderyn | 0 altos · 9 categorías de bajos, todas revisadas (abajo) |
| Mythril | 0 hallazgos en Vault, Router y OracleGuard · 3 bajos de diseño en GuardianCanceller |

## 1. Calidad y estructura del código

**Estilo.** `forge fmt` (formato oficial de Foundry, que sigue la Solidity Style Guide), `forge lint` y **Solhint** con la configuración `solhint:recommended` más reglas estrictas (`.solhint.json`):
- versión exacta del compilador;
- NatSpec obligatorio;
- sin imports globales ni sin usar;
- líneas de hasta 120 caracteres.

Las tres herramientas dan 0 avisos y corren en cada PR.

Reglas de Solhint desactivadas, con su motivo:
- `import-path-check`: Solhint no entiende los *remappings* de Foundry (`@openzeppelin/…`). Las rutas las valida el compilador.
- `gas-indexed-events`: sugiere indexar montos. Los eventos indexan las direcciones, que es por lo que se filtra.
- `gas-strict-inequalities`: microoptimización. Las comparaciones `>=` y `<=` están elegidas por su significado (por ejemplo, "hasta el tope inclusive").

Cada excepción puntual dentro del código (`solhint-disable`, `slither-disable`, `forge-lint: disable`) tiene un comentario al lado que explica por qué es intencional.

**NatSpec.** Cada contrato tiene `@title`, `@author`, `@notice` y `@dev`. Cada función (pública e interna), evento, error, struct, modificador y variable pública tiene `@notice` o `@dev`, más `@param` y `@return`. Solhint lo verifica con `use-natspec` en modo error.

**Código muerto.** Se revisó con un script propio y con los detectores de Slither (`dead-code`, `unused-state`, `unused-return`, `constable-states`, `immutable-states`):
- Todos los errores se usan, todos los eventos se emiten y todas las funciones internas e imports tienen uso.
- Se **eliminó** la última comprobación de `_sharesFor`: era imposible que se cumpliera. La demostración quedó en el NatSpec y la confirma `testFuzz_sharesFor_neverExceedsAmounts`, con 100.000 corridas sin contraejemplo.
- Se cambiaron los valores iniciales del oráculo, que estaban escritos como números sueltos, por constantes con nombre (`DEFAULT_*`).

**Versión fija.** `src/`, `script/` y `test/` usan `pragma solidity 0.8.38;`, sin `^`, y `foundry.toml` fija `solc_version = "0.8.38"`.

## 2. Cobertura de pruebas

```
| File                      | % Lines           | % Statements      | % Branches        | % Funcs           |
| src/BietixRouter.sol      | 100.00% (248/248) | 100.00% (335/335) | 100.00% (63/63)   | 100.00% (42/42)   |
| src/BietixVault.sol       | 100.00% (89/89)   | 100.00% (111/111) | 100.00% (21/21)   | 100.00% (16/16)   |
| src/GuardianCanceller.sol | 100.00% (32/32)   | 100.00% (35/35)   | 100.00% (7/7)     | 100.00% (7/7)     |
| src/OracleGuard.sol       | 100.00% (177/177) | 100.00% (241/241) | 100.00% (46/46)   | 100.00% (35/35)   |
| Total                     | 100.00% (546/546) | 100.00% (722/722) | 100.00% (137/137) | 100.00% (100/100) |
```
Para reproducirlo: `forge coverage --report summary --no-match-coverage "(test|script|lib)"`.

| Tipo | Dónde | Qué cubre |
| --- | --- | --- |
| Unitarias | `test/unit/` | Cada función en el camino feliz y en cada error. Permisos de cada rol. Regresiones de la revisión interna. Firma única. Ramas defensivas (`Coverage.t.sol`) |
| Cumplimiento ERC-20 | `test/unit/ERC20Compliance.t.sol` | Metadatos, `transfer`/`approve`/`transferFrom` con sus eventos, valor 0, aprobación infinita, transferencias sin comisión ni bloqueo, `permit` EIP-2612 |
| Fuzz | `test/fuzz/` y otros | Ida y vuelta sin ganancia, canje en partes, redondeo a favor del vault, reserva de `sharesFor` |
| Invariantes | `test/invariant/` | Respaldo 100%, salida siempre abierta, suma de saldos, tope de emisión, parámetros acotados y unidades inmutables, con secuencias aleatorias de operaciones |
| Integración y estrés | `test/integration/Stress.t.sol` | 60 usuarios, montos de $100 a $25.000, USDC y USDT, cambios de precio, transferencias entre usuarios, ventas y salida masiva con todo pausado |
| Fork de Arbitrum One | `test/fork/` | WBTC, WETH, USDC, USDT, Chainlink y Uniswap reales. KyberSwap con rutas en vivo. `permit` real del USDC |
| Despliegue y gobierno | `test/script/Deploy.t.sol` | El script completo, más un simulacro de propuesta, cancelación y reemplazo del guardián |

Además del fork, el despliegue de testnet se probó en vivo con un simulacro de gobierno completo (ver `claude/despliegue-testnet.md` en el proyecto).

## 3. Análisis estático

**Slither** (todos los detectores, `slither.config.json`): **0 resultados.**

**Aderyn 0.6.8**: **0 altos.** El único alto inicial era un falso positivo: leer el vault dentro del constructor del Router, cuando todavía no hay código al que reentrar. Quedó explicado en el código. Los bajos:

| Aviso | Decisión |
| --- | --- |
| L-1 Centralización | De diseño: los permisos están acotados y pasan por Timelock, Safe y guardián (ver sección 4) |
| L-2 Literal numérico grande (`BPS = 10_000`) | Ya es una constante con nombre |
| L-3 Literal en vez de constante | Corregido en los valores iniciales del oráculo. El resto es el tamaño de un arreglo (`uint256[4]`), `18` decimales y `10 ** decimales` |
| L-4 Variable local que tapa una de estado | Son campos de los structs `Config`; no tapan nada |
| L-5 `revert` dentro de un bucle | Intencional: la validación de los pasos de swap tiene que revertir |
| L-6 Dirección sin verificar | `proposeGuardian(address(0))` es válido a propósito: quita el veto |
| L-7 Comentarios "TODO" | Falso positivo: detecta la palabra "todo" en español |
| L-8 Valor de retorno sin usar | `_grantRole` y los retornos de `mintInKind`/`redeemInKind`: lo recibido se mide por saldos |
| L-9 Variable sin inicializar | Los contadores `i` de los bucles empiezan en 0 por defecto |

**Mythril 0.24.8** (ejecución simbólica, 2 transacciones, hasta 15 minutos por contrato):

| Contrato | Resultado |
| --- | --- |
| BietixVault | Sin hallazgos |
| BietixRouter | Sin hallazgos |
| OracleGuard | Sin hallazgos |
| GuardianCanceller | 3 bajos de diseño. Dos son por usar `block.timestamp` en las esperas: el margen de manipulación es de segundos y las esperas son de días. El tercero es una "llamada a una dirección del usuario" en `cancel`, que es el Timelock fijado en el constructor |

## 4. Puntos críticos de la lógica del token

**¿El administrador puede congelar fondos o acuñar sin control?** No.
- `_mint` se usa en un solo lugar, `mintInKind`, que en la misma transacción exige recibir el WBTC y el WETH exactos que respaldan los tokens.
- No existen funciones para congelar cuentas, poner direcciones en una lista negra ni bloquear transferencias: el token no sobrescribe `_update`.
- `redeemInKind` no se puede pausar y no depende de oráculos ni del Router.
- Ningún rol puede sacar el colateral: `sweep` rechaza WBTC y WETH.
- Las unidades por token son inmutables y los contratos no se pueden actualizar (sin proxy).

Los permisos que existen están acotados. Lo que aumenta el riesgo (subir comisiones hasta el 1%, cambiar el oráculo, agregar agregadores) pasa por el **Timelock**, que el guardián puede vetar. Lo que lo reduce (pausar, bajar límites) es inmediato.

> **Pendiente para mainnet:** que el administrador del Timelock sea un multisig (Safe 2 de 3) y no una sola billetera. Con una billetera única, los auditores lo marcan como riesgo de centralización medio. El Safe es gratuito: solo se paga el gas.

**¿Hay comisión por transferencia?** No. BIETIX es un ERC-20 estándar y las transferencias mueven exactamente el monto pedido (lo prueba `test_transfer_movesExactAmountAndEmits`). Las comisiones se cobran solo al acuñar (In-Kind) y al comprar o vender por el Router. Por eso el token es compatible con cualquier DEX, billetera o protocolo. Además, el Vault y el Router **rechazan** tokens con comisión al recibir fondos: miden el saldo antes y después y exigen que llegue exactamente lo pedido.

**¿Cumple el estándar ERC-20?** Sí. Hereda `ERC20` y `ERC20Permit` de OpenZeppelin v5.1 sin modificaciones. Tiene todas las funciones obligatorias de EIP-20 (`totalSupply`, `balanceOf`, `transfer`, `transferFrom`, `approve`, `allowance`), los eventos `Transfer` y `Approval`, los metadatos (`name`, `symbol`, `decimals` = 18) y `permit` (EIP-2612). Lo prueba `ERC20Compliance.t.sol`.

## 5. Lista de control de "tax tokens" (impuesto, quema automática, acuñación continua)

BIETIX **no es un tax token**. No cobra impuesto en las transferencias, no tiene quema automática y no tiene acuñación continua ni inflación. Las comisiones existen, pero solo en las funciones de entrada y salida del protocolo (`mintInKind`, `buy`, `sell`), nunca dentro de `transfer`. Pruebas: `test/unit/TokenMechanics.t.sol`.

| Punto de la lista | Cómo aplica a Bietix | Evidencia |
| --- | --- | --- |
| Redondeo en el cálculo de comisiones | Se multiplica antes de dividir con `Math.mulDiv` (sin desbordes ni pérdida de precisión). Las comisiones redondean hacia arriba y los pagos hacia abajo, siempre a favor del protocolo, así que el vault nunca pierde ni una unidad | Fuzz de redondeo e ida y vuelta; invariante de respaldo |
| Compatibilidad con DEX | Total: `transfer` es el de OpenZeppelin sin cambios. No hace falta `...SupportingFeeOnTransferTokens` | `test_transfer100_receiverGets100_noTaxAnywhere` |
| Tope de comisión en código | Sí, constante e imposible de cambiar: 1% en el vault (`MAX_MINT_FEE_BPS`) y 1% en compra y venta del Router (`MAX_FEE_BPS`). Subirla dentro del tope requiere el Timelock | Pruebas de `setMintFee`, `setBuyFee`, `setSellFee` y constructores |
| Listas de exentos | No aplica: no hay impuesto del que eximir | — |
| Quema y `totalSupply` | Solo se quema al canjear (`redeemInKind`), con `_burn` de OpenZeppelin: baja el saldo y el `totalSupply` y emite `Transfer` a `address(0)`. No hay quema en transferencias ni en funciones del sistema | `test_tenRedeems_supplyDropsExactly`, `test_tenTransfers_supplyUnchanged` |
| Acuñación protegida | **No existe una función `mint` de administrador.** La única forma de crear tokens es `mintInKind`, que cualquiera puede usar pero solo depositando en la misma transacción el WBTC y el WETH exactos que los respaldan. Sin colateral revierte, también para el administrador | `test_noAdminMintFunctionExists`, `test_mintWithoutCollateral_reverts`, `test_adminCannotMintWithoutCollateralOrAboveCap`, `testFuzz_everyMintIsFullyBacked` |
| Tope de suministro | `supplyCap` limita la emisión total. No es política monetaria: cada token nuevo trae su colateral, así que no hay inflación. El tope es un límite de riesgo que el guardián puede bajar al instante y el Timelock subir | Invariante `totalSupply ≤ supplyCap` |
| Emisión por tiempo | No hay emisión por tiempo ni recompensas | — |

**¿Las comisiones se cobran en el propio token y se venden automáticamente?** No, y nunca se venden de forma automática:
- La comisión **In-Kind** se cobra en WBTC y WETH y va directo a tesorería en la misma transacción.
- Las comisiones del **Router** se cobran en la stablecoin del usuario (USDC o USDT) y van directo a tesorería: en la compra se descuentan antes de los swaps y en la venta sobre lo obtenido.

Ningún contrato guarda comisiones ni hace swaps para pagarlas, así que no hay un flujo de "vender impuestos" que pueda ser reentrado o manipulado.

## Cómo repetir esta revisión

```bash
forge fmt --check && forge build && forge lint
forge test
forge coverage --report summary --no-match-coverage "(test|script|lib)"
slither .
npx solhint@6 'src/**/*.sol'
npx @cyfrin/aderyn . --src src
myth analyze src/BietixVault.sol:BietixVault --solv 0.8.38 --solc-json docs/mythril-solc.json --execution-timeout 900 -t 2
```

En cada PR, GitHub Actions corre el formato, la compilación sin avisos, las pruebas, Slither y Solhint.
