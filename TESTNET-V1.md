# Rama `testnet-v1`: código exacto desplegado en Arbitrum Sepolia

Esta rama congela el código **tal como se desplegó en Arbitrum Sepolia el 3 de noviembre de 2026**
(con los nombres anteriores `DuoxVault` / `DuoxRouter`). Sirve para **verificar esos contratos en Arbiscan**,
que exige que el código compilado sea idéntico al desplegado.

No se desarrolla sobre esta rama: el desarrollo sigue en `main` (con el nombre Bietix).

## Verificar los contratos de testnet

```bash
git fetch origin
git checkout testnet-v1
forge script script/DeployTestnet.s.sol --rpc-url arbitrum_sepolia --account duox-testnet --resume --broadcast --verify
git checkout main
```

Con `--resume` **no se vuelve a desplegar nada**: todas las transacciones ya están confirmadas, así que solo
se publica el código en Arbiscan. Requiere `ETHERSCAN_API_KEY` en `.env` y la carpeta `broadcast/` del despliegue original.
