# Política de seguridad

Bietix custodia fondos de usuarios. Si encontrás una vulnerabilidad, te pedimos que nos la reportes **en privado** antes de hacerla pública.

## Cómo reportar

1. Entrá a la pestaña **Security** de este repositorio y hacé clic en **Report a vulnerability**
   (reporte privado de GitHub). Solo el equipo de Bietix puede verlo.
2. Incluí la descripción del problema, el contrato y la función afectados, y si podés una prueba de concepto
   (idealmente una prueba de Foundry).
3. **No** abras un *issue* público, no lo publiques en redes y no lo pruebes contra contratos en mainnet.

Respondemos dentro de las 72 horas y te mantenemos al tanto hasta que esté corregido.
Con tu acuerdo, te damos crédito en el informe público.

## Alcance

| En alcance | Fuera de alcance |
| --- | --- |
| `src/` (BietixVault, BietixRouter, OracleGuard, GuardianCanceller) | Contratos de prueba en `script/testnet/` y `test/` |
| `script/DeployBase.sol` y `script/Deploy.s.sol` | Ataques que requieren las llaves del Safe o del guardián |
| El sitio `https://bietix.com` (por ejemplo, una forma de inyectar código o cambiar direcciones) | Fallas de Chainlink, WBTC, USDC, USDT o los agregadores en sí mismos |
| | Ataques de denegación de servicio a la red o al sitio por volumen |

## Estado

- **Mainnet:** todavía no desplegado. Las direcciones oficiales se publicarán solo en `https://bietix.com` y en este repositorio.
- **Testnet (Arbitrum Sepolia):** desplegado con fines de prueba; sus tokens no tienen valor.
- **Auditoría externa:** en preparación. El informe se publicará en este repositorio.
- **Programa de recompensas:** se abrirá junto con el lanzamiento en mainnet.

## Direcciones oficiales

Desconfiá de cualquier sitio, token o contrato que diga ser Bietix y no figure aquí o en `https://bietix.com`.
Bietix nunca te va a pedir tu frase semilla ni que firmes algo por mensaje directo.
