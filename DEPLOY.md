# Guía de despliegue de BIETIX

Hay dos scripts. Los dos usan la misma lógica (`script/DeployBase.sol`) y al terminar **verifican solos**
que la billetera que desplegó no conserve ningún permiso. Si algo no está bien, el script se detiene.

| Script | Red | Qué despliega |
|---|---|---|
| `script/DeployTestnet.s.sol` | Arbitrum Sepolia | Tokens, oráculos y DEX **de prueba** + Timelock, OracleGuard, BietixVault, BietixRouter |
| `script/Deploy.s.sol` | Arbitrum One | Timelock, OracleGuard, BietixVault, BietixRouter con WBTC, WETH, USDC, USDT y Chainlink reales |

## Qué queda configurado al desplegar

```
Safe ──propone──▶ Timelock ──(espera)──▶ ejecuta cambios en Vault, OracleGuard y Router
Guardián ──puede cancelar propuestas del Timelock, pausar y reducir límites
Billetera que despliega ──▶ ningún permiso (renuncia en la misma transacción de despliegue)
```

- **Timelock:** el Safe es el único que propone y ejecuta. El Safe y el guardián pueden cancelar.
- **Vault, OracleGuard y Router:** el administrador es el Timelock desde el primer bloque.
- **Feeds, stablecoins y agregadores:** se configuran en el constructor, así que el sistema funciona
  desde el despliegue sin esperar al timelock.

---

## A. Testnet (Arbitrum Sepolia)

### 1. Preparar billeteras (una sola vez)

Necesitás **4 direcciones distintas**. En testnet pueden ser billeteras comunes (Rabby o MetaMask):

| Rol | Para qué |
|---|---|
| Despliegue | Paga el gas del despliegue. Queda **sin permisos** |
| Safe | Propone/ejecuta cambios. En testnet podés crear un Safe real en app.safe.global (red Arbitrum Sepolia) o usar una billetera común para practicar |
| Guardián | Pausa y cancela en emergencias |
| Tesorería | Recibe las comisiones |

### 2. Cuenta de despliegue cifrada (nunca una clave en texto plano)

```bash
cast wallet import duox-testnet --interactive
```

Pegás la clave privada de la billetera de despliegue y elegís una contraseña. (En testnet se usa la cuenta `duox-testnet`, creada antes del cambio de nombre; para mainnet se usa una hardware wallet con `--ledger`.) Queda guardada cifrada en tu computadora.

### 3. ETH de prueba

Pedí ETH de Arbitrum Sepolia en una faucet (por ejemplo la de Alchemy o la de QuickNode) para la billetera de despliegue.

### 4. Completar `.env`

`ARBITRUM_SEPOLIA_RPC_URL` (en Alchemy creá una app de "Arbitrum Sepolia"), `SAFE_ADDRESS`, `GUARDIAN_ADDRESS`,
`TREASURY_ADDRESS`, `ETHERSCAN_API_KEY` (opcional, para verificar en Arbiscan) y `TIMELOCK_DELAY=300`.

### 5. Simular y desplegar

```bash
source .env
# Simulación (no envía nada, no gasta gas):
forge script script/DeployTestnet.s.sol --rpc-url $ARBITRUM_SEPOLIA_RPC_URL --account duox-testnet
# Despliegue real en testnet:
forge script script/DeployTestnet.s.sol --rpc-url $ARBITRUM_SEPOLIA_RPC_URL --account duox-testnet --broadcast --verify
```

Al final se imprimen todas las direcciones. **Guardalas** (también quedan en `broadcast/`).

### 6. Usarlo

- Pedí tokens de prueba llamando a `faucet()` en cada token (desde Arbiscan → *Write Contract*).
- Los feeds de prueba no se actualizan solos: llamá `refresh()` en cada uno al menos una vez por día.
- Para simulacros, quien desplegó puede cambiar precios: `setAnswer(...)` en el feed de WBTC/BTC para
  simular un depeg, o `setStatus(1, ahora)` en el sequencer para simular una caída.

---

## B. Mainnet (Arbitrum One) — Fase 2

> ⚠️ No desplegar en mainnet antes de completar la lista de verificación 6.10 de las especificaciones
> (revisión externa de seguridad y consulta legal incluidas).

1. **Crear el Safe** en app.safe.global, red Arbitrum One, 2 de 3 firmantes con hardware wallets.
2. **Guardián:** una hardware wallet distinta de los firmantes del Safe.
3. **Completar `.env`**: todas las variables de la sección "Solo mainnet". Revisar los heartbeats de los feeds
   en la documentación de Chainlink y fijar `UNIT_ETH` el día del lanzamiento.
4. **Simular** (no envía nada):
   ```bash
   source .env
   forge script script/Deploy.s.sol --rpc-url $ARBITRUM_RPC_URL --ledger
   ```
5. **Desplegar** con la hardware wallet:
   ```bash
   forge script script/Deploy.s.sol --rpc-url $ARBITRUM_RPC_URL --ledger --broadcast --verify
   ```
6. **Publicar** las direcciones y verificar en Arbiscan que los cuatro contratos estén verificados.

## Cómo se hace un cambio después del despliegue

Ejemplo: subir el límite de supply.

1. En la app del Safe → *Transaction Builder* → contrato **Timelock** → función `schedule` con:
   `target` = BietixVault, `value` = 0, `data` = llamada codificada a `increaseSupplyCap(nuevoLimite)`,
   `predecessor` = 0x0, `salt` = cualquier valor, `delay` = espera configurada.
2. Firmás con 2 de 3 → queda programado y visible públicamente.
3. Pasada la espera, otra transacción del Safe llama a `execute` con los mismos datos.
4. Si la propuesta fuera maliciosa, el guardián llama a `cancel(id)` durante la espera.
