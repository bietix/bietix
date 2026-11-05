# Manual de incidentes de Bietix

Qué hacer, quién lo hace y con qué comando cuando algo sale mal. Primero se protege a los usuarios y después se investiga.

**Regla de oro:** el canje In-Kind (`redeemInKind`) nunca se puede pausar. Pase lo que pase, cada holder puede retirar su WBTC y su WETH. Toda la respuesta a incidentes consiste en frenar lo demás mientras se resuelve.

## Quién es quién

| Rol | Quién | Herramienta | Qué puede hacer rápido |
| --- | --- | --- | --- |
| Guardián | _completar: nombre_ | Ledger + `cast` | Pausar, bajar límites, quitar stables o agregadores, endurecer oráculos, cancelar propuestas del Timelock |
| Firmantes del Safe (2 de 3) | _completar: 3 nombres_ | app.safe.global con hardware wallets | Todo lo del guardián, más despausar, revocar al guardián y proponer cambios al Timelock |
| Comunicación | _completar_ | Sitio, X, Telegram | Avisar a los usuarios |

**Contactos de emergencia:** _completar teléfonos o canal privado. Tienen que funcionar a cualquier hora._

## Cómo llegan las alertas

- **Monitoreo cada 15 minutos** (`.github/workflows/monitor.yml`). Si algo falla, abre un issue "Alerta de monitoreo" en GitHub, y GitHub avisa por mail y en la app. Cuando el problema se resuelve, cierra el issue solo.
- **Eventos en tiempo real:** alertas de Tenderly para `CallScheduled` (Timelock), `PauseChanged`, `ParamChanged`, `GuardianChangeProposed` y `DefaultAdminTransferScheduled`. _Pendiente de configurar al desplegar en mainnet._

## Niveles

| Nivel | Ejemplo | Respuesta |
| --- | --- | --- |
| **Crítico** | Falta colateral, cambio de administrador no planeado, propuesta maliciosa en el Timelock | Pausar todo en minutos y convocar al Safe |
| **Advertencia** | Oráculo sin precio, depeg, cupo de ventas casi agotado, pausa activa | Revisar en menos de 1 hora y decidir si hay que actuar |
| **Info** | Límite de emisión cerca del tope | Planificar el ajuste por Timelock |

## Comandos del guardián

Preparación (una vez): en el `.env`, `ARBITRUM_RPC_URL` (app `bietix-dev`) y las direcciones oficiales `VAULT`, `ROUTER`, `ORACLE` y `CANCELLER`. La Ledger tiene que estar conectada y con la app de Ethereum abierta.

```bash
source .env
# Pausar todo el Router (compra y venta). El canje sigue abierto.
cast send $ROUTER "pause()" --ledger --rpc-url $ARBITRUM_RPC_URL
# Solo compras / solo ventas
cast send $ROUTER "pauseBuys()" --ledger --rpc-url $ARBITRUM_RPC_URL
cast send $ROUTER "pauseSells()" --ledger --rpc-url $ARBITRUM_RPC_URL
# Pausar la acuñación en el Vault (también frena las compras)
cast send $VAULT "pauseMint()" --ledger --rpc-url $ARBITRUM_RPC_URL
# Quitar una stablecoin o un agregador
cast send $ROUTER "removeStable(address)" <TOKEN> --ledger --rpc-url $ARBITRUM_RPC_URL
cast send $ROUTER "removeSwapTarget(address)" <AGREGADOR> --ledger --rpc-url $ARBITRUM_RPC_URL
# Cancelar una propuesta del Timelock (el id sale del evento CallScheduled)
cast send $CANCELLER "cancel(bytes32)" <ID> --ledger --rpc-url $ARBITRUM_RPC_URL
```

Para **despausar** hace falta el Safe (rol `UNPAUSER_ROLE`): Transaction Builder → contrato → `unpause()`. El guardián no puede despausar: es intencional.

## Escenarios

### 1. Falta colateral (crítico)
Alerta "Respaldo 100%". No debería poder pasar nunca: si pasa, hay un bug grave.
1. **Guardián:** `pause()` en el Router y `pauseMint()` en el Vault.
2. **Safe:** se reúne y revisa las últimas transacciones del Vault en Arbiscan.
3. **Comunicación:** aviso de que compra y venta están pausadas y de que el canje In-Kind sigue disponible.
4. Contactar a los auditores. No despausar hasta entender la causa.

### 2. Propuesta sospechosa en el Timelock (crítico)
Un `CallScheduled` que nadie del equipo reconoce: indica que el Safe está comprometido.
1. **Guardián:** `cancel(id)` en GuardianCanceller. Repetir con cada propuesta nueva.
2. **Firmantes que no estén comprometidos:** reemplazar en el Safe al firmante robado (Settings → Owners). Con 2 de 3 alcanza.
3. Si el atacante llama a `proposeGuardian` para sacar al guardián, tiene que esperar 7 días: es el tiempo para avisar a los usuarios que salgan In-Kind.

### 3. Cambio de administrador en curso (crítico)
Alerta "Administrador = Timelock" con "transferencia de admin en curso". Ese cambio solo puede iniciarlo el Timelock, así que antes hubo una propuesta: es el escenario 2.
1. Verificar en Arbiscan si se planeó. Si no: escenario 2.
2. **Safe:** se puede frenar con `cancelDefaultAdminTransfer()` vía Timelock, y el guardián cancela cualquier propuesta relacionada.

### 4. Oráculos sin precio (advertencia)
Alerta "Oráculos". El sistema ya frenó solo compras y ventas: precio viejo, sequencer de Arbitrum caído o precio fuera de rango.
- **Mainnet:** suele ser un problema de Chainlink o de Arbitrum y se resuelve solo. Avisar a los usuarios, mirar status.arbitrum.io y data.chain.link, y no tocar nada.
- **Testnet:** los oráculos de prueba vencen a las 26 h. Refrescar:
  `forge script script/testnet/Interact.s.sol --sig "refreshFeeds()" --rpc-url arbitrum_sepolia --account duox-testnet --broadcast`

### 5. WBTC pierde la paridad con BTC (advertencia)
Alerta "Paridad WBTC/BTC". Por debajo de 0,99 avisa; por debajo de 0,98 el contrato bloquea solo las compras. Las ventas siguen abiertas para que los usuarios puedan salir.
1. Seguir las noticias de BitGo/WBTC.
2. Si empeora rápido, el **guardián** puede usar `pauseBuys()` antes de llegar a 0,98.
3. No hay que pausar las ventas: salir a precio real es un derecho del usuario.

### 6. Una stablecoin pierde la paridad
Por debajo de 0,98 el contrato ya no la acepta en compras.
1. **Guardián:** `removeStable(<token>)` si el problema es serio (congelamiento o hackeo del emisor).
2. Las compras y ventas siguen con la otra stable.

### 7. Agregador comprometido o fallando
Swaps que fallan en masa, o noticias de un hackeo de KyberSwap.
1. **Guardián:** `removeSwapTarget(0x6131B5fae19EA4f9D964eAc0408E4408b66337b5)`. El Router queda sin agregador y compra y venta fallan, pero el canje sigue.
2. **Netlify:** si hace falta, apagar `/api/swap` quitando la variable `BIETIX_ROUTER_42161`.
3. Para volver: el Safe propone agregar otro agregador vía Timelock.

Recordatorio: aunque el agregador sea malicioso, el contrato no le deja llevarse más de lo aprobado en esa operación. El daño queda limitado a la operación en curso.

### 8. Bug en el Router o en el OracleGuard
1. **Guardián:** `pause()` en el Router.
2. Corregir, auditar la corrección y desplegar un Router nuevo. El Vault no cambia y no hay que migrar fondos.
3. **Safe:** pasar el sitio al Router nuevo. El viejo queda pausado para siempre.

### 9. Sitio web comprometido (el riesgo más probable)
Señales: cambios en bietix.com que nadie hizo, direcciones de contrato distintas, usuarios que reportan firmas raras.
1. **Bajar el sitio ya:** en Netlify, Deploys → **Lock to stop auto publishing** y publicar una versión vieja conocida. Si no hay acceso a Netlify, en Cloudflare apuntar el DNS a una página de mantenimiento.
2. **Avisar en todos los canales:** "No firmen nada en bietix.com hasta nuevo aviso".
3. Cambiar las contraseñas y revisar el 2FA de GitHub, Netlify, Cloudflare y el email. Revisar los últimos commits y deploys.
4. Los contratos no se ven afectados: un sitio falso solo puede engañar a quien firme.

### 10. Llave del guardián perdida o robada
1. **Safe, ya:** `revokeGuardian(<guardián>)` en el Vault, el Router y el OracleGuard.
2. **Safe:** `proposeGuardian(<nuevo>)` en GuardianCanceller, y `applyGuardianChange()` a los 7 días.
3. Mientras tanto, el ladrón puede cancelar propuestas del Timelock, pero no puede tocar fondos ni parámetros. Si molesta, `proposeGuardian(address(0))` también tarda 7 días.

### 11. Firmante del Safe comprometido
1. Los otros 2 firmantes lo quitan del Safe y suman uno nuevo (Settings → Owners).
2. Revisar si hay propuestas pendientes en el Timelock (escenario 2).

### 12. Cupo de ventas de 24 h agotado (advertencia)
Puede ser mucha salida real o alguien intentando bloquear a otros.
1. El cupo se recupera solo, de forma lineal, en 24 h. Los usuarios pueden salir In-Kind sin límite.
2. Si la demanda es real y sostenida, el **Safe** puede subir `sellLimitUsd` vía Timelock.

## Después de cada incidente

1. **Informe público** dentro de las 72 h: qué pasó, a quién afectó, qué se hizo y qué cambia.
2. Revisar este manual con lo aprendido.
3. Despausar solo cuando el Safe esté de acuerdo, con 2 de 3 firmas.

## Simulacros

Al menos uno por trimestre en testnet: pausar y despausar, cancelar una propuesta, reemplazar al guardián. Medir cuánto tarda cada paso desde la alerta.
