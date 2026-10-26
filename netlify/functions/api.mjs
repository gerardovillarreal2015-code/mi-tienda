import { neon } from "@neondatabase/serverless";

const sql = neon(process.env.DATABASE_URL);

// Tablas permitidas y columnas que se pueden guardar
const TABLAS = {
  categorias: ["nombre"],
  productos: ["codigo", "nombre", "categoria_id", "precio_total_compra", "unidades_compra", "precio_venta", "stock_minimo"],
  inventario_movimientos: ["producto_id", "proveedor_id", "tipo", "cantidad", "precio_total", "fecha_vencimiento"],
  clientes: ["nombre", "telefono", "correo"],
  proveedores: ["empresa", "contacto", "telefono"],
  ventas: [],       // se crean con crearVenta (productos, stock y caja)
  abonos: [],       // se crean con crearAbono (deuda y caja)
  venta_items: [],  // solo lectura
  lotes: [],        // solo lectura (vencimientos)
  caja_movimientos: ["concepto", "tipo", "monto"],
};

// Para leer, algunas tablas usan una vista con datos ya combinados
const LECTURA = {
  categorias: "v_categorias",
  productos: "v_productos",
  inventario_movimientos: "v_inventario",
  ventas: "v_ventas",
  clientes: "v_clientes",
  venta_items: "v_venta_items",
  lotes: "v_lotes",
};
const ORDEN = { lotes: "dias_restantes, id" }; // lo demás se lee del más nuevo al más antiguo

// Valores por defecto cuando el formulario deja un campo vacío
const DEFECTOS = {
  productos: { precio_total_compra: 0, unidades_compra: 1, precio_venta: 0, stock_minimo: 5 },
  inventario_movimientos: { precio_total: 0 },
};

const json = (data, status = 200) =>
  new Response(JSON.stringify(data), { status, headers: { "Content-Type": "application/json" } });
const fallo = (msg) => json({ error: msg }, 400);

// Venta con productos: valida stock, calcula el total (precio de venta x cantidad) con el catálogo,
// y en UNA sola sentencia guarda la venta, sus productos y lo que se pagó ahora en caja.
async function crearVenta(b) {
  const debe = Number(b.debe || 0);
  if (!(debe >= 0)) return fallo("El valor que debe no es válido");
  if (debe > 0 && !b.cliente_id) return fallo("Si el cliente debe algo, hay que elegir el cliente");

  const lineas = new Map();
  for (const it of Array.isArray(b.items) ? b.items : []) {
    const id = Number(it.producto_id), cant = Number(it.cantidad);
    if (!Number.isInteger(id) || !Number.isInteger(cant) || cant <= 0)
      return fallo("Cada producto debe tener una cantidad entera mayor a 0");
    lineas.set(id, (lineas.get(id) || 0) + cant);
  }
  if (!lineas.size) return fallo("Agrega al menos un producto a la venta");

  const prods = await sql.query(
    "SELECT id, nombre, precio_venta, stock FROM v_productos WHERE id IN (SELECT jsonb_array_elements_text($1::jsonb)::int)",
    [JSON.stringify([...lineas.keys()])]);
  if (prods.length !== lineas.size) return fallo("Un producto de la venta no existe");

  let total = 0;
  for (const p of prods) {
    const cant = lineas.get(p.id);
    if (cant > p.stock) return fallo(`No hay stock suficiente de ${p.nombre} (disponible: ${p.stock})`);
    total += cant * Number(p.precio_venta);
  }
  if (!(total > 0)) return fallo("El total de la venta debe ser mayor a 0");
  if (debe > total) return fallo("Lo que debe no puede ser mayor al total de la venta");

  const items = [...lineas].map(([producto_id, cantidad]) => ({ producto_id, cantidad }));
  const r = await sql.query(
    `WITH v AS (
       INSERT INTO ventas (cliente_id, debe, total) VALUES ($1, $2, $3) RETURNING id, total, debe
     ), it AS (
       INSERT INTO venta_items (venta_id, producto_id, cantidad, precio_unitario, costo_unitario)
       SELECT v.id, x.producto_id, x.cantidad, p.precio_venta, p.precio_compra
       FROM v CROSS JOIN jsonb_to_recordset($4::jsonb) AS x(producto_id int, cantidad int)
       JOIN v_productos p ON p.id = x.producto_id
       RETURNING id
     ), cj AS (
       INSERT INTO caja_movimientos (concepto, tipo, monto, venta_id)
       SELECT 'Venta #' || v.id, 'Ingreso', v.total - v.debe, v.id FROM v WHERE v.total - v.debe > 0
       RETURNING id
     )
     SELECT id FROM v`,
    [b.cliente_id || null, debe, total, JSON.stringify(items)]);
  return json({ id: r[0].id, total, debe }, 201);
}

// Abono: no puede superar la deuda, y entra a caja como ingreso
async function crearAbono(b) {
  const monto = Number(b.monto);
  if (!(monto > 0)) return fallo("El abono debe ser mayor a 0");
  const d = await sql.query("SELECT deuda FROM v_clientes WHERE id = $1", [b.cliente_id]);
  if (!d.length) return fallo("Cliente no encontrado");
  if (monto > Number(d[0].deuda)) return fallo("El abono supera la deuda actual del cliente");
  const r = await sql.query(
    `WITH a AS (
       INSERT INTO abonos (cliente_id, monto) VALUES ($1, $2) RETURNING id, cliente_id, monto
     )
     INSERT INTO caja_movimientos (concepto, tipo, monto, abono_id)
     SELECT 'Abono de ' || c.nombre, 'Ingreso', a.monto, a.id FROM a JOIN clientes c ON c.id = a.cliente_id
     RETURNING abono_id AS id`,
    [b.cliente_id, monto]);
  return json(r[0], 201);
}

// Reglas de negocio de las tablas que se guardan directo
function validar(tabla, b) {
  if (tabla === "productos") {
    if (!(Number.isInteger(Number(b.unidades_compra)) && Number(b.unidades_compra) > 0))
      return "Las unidades compradas deben ser un número entero mayor a 0";
    if (!(Number(b.precio_total_compra) >= 0) || !(Number(b.precio_venta) >= 0))
      return "Los precios no pueden ser negativos";
  }
  if (tabla === "inventario_movimientos") {
    const cant = Number(b.cantidad);
    if (!Number.isInteger(cant) || cant === 0) return "La cantidad debe ser un número entero distinto de 0";
    if (b.tipo === "Compra" && cant <= 0) return "Una compra debe tener cantidad mayor a 0";
    if (!(Number(b.precio_total) >= 0)) return "El precio total no puede ser negativo";
  }
  return null;
}

export default async (req) => {
  if (req.headers.get("x-admin-key") !== process.env.ADMIN_KEY)
    return json({ error: "No autorizado" }, 401);

  const tabla = new URL(req.url).searchParams.get("tabla");
  const cols = TABLAS[tabla];
  if (!cols) return json({ error: "Tabla no válida" }, 400);

  try {
    if (req.method === "GET") {
      const origen = LECTURA[tabla] || tabla;
      return json(await sql.query(`SELECT * FROM ${origen} ORDER BY ${ORDEN[tabla] || "id DESC"} LIMIT 500`));
    }
    if (req.method === "POST") {
      const body = await req.json();
      if (tabla === "ventas") return await crearVenta(body);
      if (tabla === "abonos") return await crearAbono(body);
      if (!cols.length) return json({ error: "Método no permitido" }, 405);
      for (const [k, v] of Object.entries(DEFECTOS[tabla] || {})) body[k] ??= v;
      const problema = validar(tabla, body);
      if (problema) return fallo(problema);
      const valores = cols.map((c) => body[c] ?? null);
      const marcas = cols.map((_, i) => `$${i + 1}`).join(",");
      const filas = await sql.query(
        `INSERT INTO ${tabla} (${cols.join(",")}) VALUES (${marcas}) RETURNING *`, valores);
      return json(filas[0], 201);
    }
    return json({ error: "Método no permitido" }, 405);
  } catch (e) {
    const duplicado = e.code === "23505";
    return json({ error: duplicado ? "Ese registro ya existe" : "Error en la base de datos" }, duplicado ? 409 : 500);
  }
};

export const config = { path: "/api" };
