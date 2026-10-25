import { neon } from "@neondatabase/serverless";

const sql = neon(process.env.DATABASE_URL);

// Tablas permitidas y columnas que se pueden guardar
const TABLAS = {
  productos: ["codigo", "nombre", "stock", "precio"],
  clientes: ["nombre", "telefono", "correo"],
  proveedores: ["empresa", "contacto", "telefono"],
  ventas: ["cliente_id", "total"],
  caja_movimientos: ["concepto", "tipo", "monto"],
};

const json = (data, status = 200) =>
  new Response(JSON.stringify(data), { status, headers: { "Content-Type": "application/json" } });

export default async (req) => {
  if (req.headers.get("x-admin-key") !== process.env.ADMIN_KEY)
    return json({ error: "No autorizado" }, 401);

  const tabla = new URL(req.url).searchParams.get("tabla");
  const cols = TABLAS[tabla];
  if (!cols) return json({ error: "Tabla no válida" }, 400);

  try {
    if (req.method === "GET") {
      return json(await sql.query(`SELECT * FROM ${tabla} ORDER BY id DESC LIMIT 200`));
    }
    if (req.method === "POST") {
      const body = await req.json();
      const valores = cols.map((c) => body[c] ?? null);
      const marcas = cols.map((_, i) => `$${i + 1}`).join(",");
      const filas = await sql.query(
        `INSERT INTO ${tabla} (${cols.join(",")}) VALUES (${marcas}) RETURNING *`, valores);
      return json(filas[0], 201);
    }
    return json({ error: "Método no permitido" }, 405);
  } catch (e) {
    return json({ error: "Error en la base de datos" }, 500);
  }
};

export const config = { path: "/api" };
