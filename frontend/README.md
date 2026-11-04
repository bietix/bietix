# Interfaz web de BIETIX

Página estática: HTML, CSS y JavaScript, sin paso de compilación. Usa [ethers v6](https://docs.ethers.org/v6/)
y fuentes alojadas en la propia carpeta (`vendor/` y `fonts/`), así que no depende de servidores externos.

## Probarla en tu computadora

Los módulos de JavaScript no funcionan abriendo el archivo con doble clic: hace falta un servidor local.
En Git Bash, desde la carpeta del proyecto:

```bash
cd frontend
python -m http.server 8000
```

Abrí **http://localhost:8000** en el navegador (con MetaMask instalado). Para cortar el servidor: `Ctrl+C`.

## Qué hace

- Muestra la fórmula del token con el precio en vivo y la composición del respaldo (BTC vs. ETH).
- **Comprar:** con USDC o USDT. Muestra cuánto recibís, la comisión total y el mínimo garantizado antes de firmar.
- **Vender:** BIETIX por USDC o USDT.
- **Canjear:** salida directa a WBTC + WETH (no depende del Router ni de los oráculos).
- **Respaldo:** WBTC y WETH en el vault frente a lo necesario, leído de la cadena.
- **Tokens de prueba:** botones de faucet (solo en testnet).
- Avisos automáticos si hay pausas, depeg del wrapper o precios no disponibles, y mensajes claros para cada error de los contratos.

## Configuración

`config.js` tiene las direcciones de cada red. La página usa Arbitrum Sepolia por defecto; con `?chain=31337`
usa una red local (anvil) para desarrollo.

## Publicarla

Como es una carpeta estática, se puede publicar gratis arrastrándola a **Netlify Drop** (app.netlify.com/drop)
o en Cloudflare Pages. (GitHub Pages también sirve, pero en tu cuenta GitHub Actions está bloqueado por el tema
de facturación.)

## Pendiente para mainnet

En testnet los swaps van por el DEX de prueba (objeto `swaps` en `app.js`). Para mainnet ese objeto se
reemplaza por la API de un agregador (1inch, 0x u Odos), que devuelve la cotización y los datos del swap.
