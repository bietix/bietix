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

## Publicación (Netlify)

El archivo `netlify.toml` en la raíz del repositorio le indica a Netlify que publique **solo esta carpeta** y que
solo vuelva a publicar cuando cambie algo acá adentro. También define cabeceras de seguridad:

- **Content-Security-Policy:** la página solo ejecuta su propio código y solo se conecta a los nodos de Arbitrum
  permitidos. Si en el futuro se agrega otra red o la API de un agregador, hay que sumar su dominio a `connect-src`.
- **X-Frame-Options:** ningún otro sitio puede mostrar la página dentro de un marco (protección contra clickjacking).

Configuración en Netlify: *Add new site → Import an existing project → GitHub → repositorio* y dejar los campos
de build vacíos (los toma de `netlify.toml`).

## Pendiente para mainnet

En testnet los swaps van por el DEX de prueba (objeto `swaps` en `app.js`). Para mainnet ese objeto se
reemplaza por la API de un agregador (1inch, 0x u Odos), que devuelve la cotización y los datos del swap.
