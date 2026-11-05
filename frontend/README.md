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

`config.js` tiene las direcciones de cada red. La página usa Arbitrum Sepolia por defecto; con `?chain=42161`
muestra Arbitrum One (aviso de "todavía no disponible" hasta cargar las direcciones del despliegue) y con
`?chain=31337` una red local (anvil) para desarrollo.

## Swaps en mainnet: KyberSwap vía `/api/swap`

En testnet los swaps van por el DEX de prueba. En Arbitrum One van por **KyberSwap**, pero el navegador nunca
habla con KyberSwap directamente: lo hace la función de Netlify `netlify/functions/swap.mjs`
(lógica en `netlify/lib/kyber.mjs`).

1. **quote:** pide la mejor ruta stable ↔ WBTC/WETH. Solo acepta esos pares y verifica que la ruta coincida con lo pedido.
2. **build:** arma la transacción con emisor y receptor = **BietixRouter** (el usuario no puede cambiarlos) y
   rechaza cualquier respuesta cuyo destino no sea el router de KyberSwap `0x6131…37b5`, que pida ETH nativo o
   cuyo monto no coincida.

Después, el contrato BietixRouter vuelve a validar todo on-chain (lista blanca, saldos, control contra oráculo).
Pruebas: `node --test frontend/netlify/lib/*.test.mjs`. Variables de entorno: ver `netlify.toml`.



## Publicación (Netlify)

El archivo `netlify.toml` en la raíz del repositorio le indica a Netlify que publique **solo esta carpeta** y que
solo vuelva a publicar cuando cambie algo acá adentro. También define cabeceras de seguridad:

- **Content-Security-Policy:** la página solo ejecuta su propio código y solo se conecta a los nodos de Arbitrum
  permitidos. El agregador se consulta a través de `/api/swap` (mismo dominio), así que no hace falta agregarlo.
- **X-Frame-Options:** ningún otro sitio puede mostrar la página dentro de un marco (protección contra clickjacking).

Configuración en Netlify: *Add new site → Import an existing project → GitHub → repositorio* y dejar los campos
de build vacíos (los toma de `netlify.toml`).

## Pendiente para mainnet

- Cargar las direcciones del despliegue en `config.js` (entrada 42161) y `BIETIX_ROUTER_42161` en Netlify.
- RPC: Alchemy (app "bietix-web", limitada a bietix.com) ya configurado para Arbitrum One.
- Firma única (permit) en testnet: activar `permit: true` en el USDC de prueba después del próximo despliegue
  (los tokens de prueba actuales no tienen `permit`).
- Agregar Odos como agregador de respaldo.
