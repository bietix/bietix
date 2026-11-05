// Función de Netlify: https://bietix.com/api/swap
// POST { action: "quote", chainId, tokenIn, tokenOut, amountIn }
// POST { action: "build", chainId, routeSummary, slippageBps, origin }
import { quote, build, BadRequest } from "../lib/kyber.mjs";

const MAX_BODY = 32 * 1024;

const reply = (status, obj) =>
  new Response(JSON.stringify(obj), {
    status,
    headers: { "content-type": "application/json; charset=utf-8", "cache-control": "no-store" },
  });

export default async (req) => {
  if (req.method !== "POST") return reply(405, { error: "Método no permitido" });
  // Solo el propio sitio puede usar este intermediario.
  const origin = req.headers.get("origin");
  const allowed = (process.env.ALLOWED_ORIGINS || "https://bietix.com").split(",").map((s) => s.trim());
  if (origin && !allowed.includes(origin)) return reply(403, { error: "Origen no permitido" });

  let body;
  try {
    const text = await req.text();
    if (text.length > MAX_BODY) return reply(413, { error: "Pedido demasiado grande" });
    body = JSON.parse(text);
  } catch {
    return reply(400, { error: "JSON inválido" });
  }

  try {
    if (body.action === "quote") return reply(200, await quote(body, process.env));
    if (body.action === "build") return reply(200, await build(body, process.env));
    return reply(400, { error: "Acción desconocida" });
  } catch (e) {
    if (e instanceof BadRequest) return reply(e.status, { error: e.message });
    console.error(e);
    return reply(500, { error: "Error interno" });
  }
};

export const config = { path: "/api/swap" };
