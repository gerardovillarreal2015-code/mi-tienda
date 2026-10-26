-- =====================================================================
--  MI TIENDA · MIGRACIÓN FINAL (reemplaza schema.sql y las migraciones anteriores)
--  Neon > SQL Editor > pegar todo > Run
--
--  • Sirve para una base NUEVA y para una que ya tenga versiones anteriores.
--  • Se puede ejecutar más de una vez sin duplicar nada.
--  • Convierte los datos existentes:
--      - productos: el precio de compra anterior pasa a "precio total de compra" (1 unidad)
--      - inventario: costo unitario x cantidad pasa a "precio total"
--      - ventas: las que eran "Crédito" quedan con debe = total
--    y elimina las columnas viejas (stock, precio_compra, costo_unitario, tipo_pago).
-- =====================================================================

-- 0) Quitar las vistas para recrearlas al final (no guardan datos)
DROP VIEW IF EXISTS v_lotes, v_venta_items, v_ventas, v_clientes, v_inventario, v_productos, v_categorias;

-- 1) Tablas base (en orden de dependencia)
CREATE TABLE IF NOT EXISTS categorias (
  id SERIAL PRIMARY KEY,
  nombre TEXT NOT NULL UNIQUE);

CREATE TABLE IF NOT EXISTS proveedores (
  id SERIAL PRIMARY KEY,
  empresa TEXT NOT NULL, contacto TEXT, telefono TEXT,
  creado TIMESTAMPTZ DEFAULT now());

CREATE TABLE IF NOT EXISTS clientes (
  id SERIAL PRIMARY KEY,
  nombre TEXT NOT NULL, telefono TEXT, correo TEXT,
  creado TIMESTAMPTZ DEFAULT now());

CREATE TABLE IF NOT EXISTS productos (
  id SERIAL PRIMARY KEY,
  codigo TEXT, nombre TEXT NOT NULL,
  creado TIMESTAMPTZ DEFAULT now());

CREATE TABLE IF NOT EXISTS ventas (
  id SERIAL PRIMARY KEY,
  cliente_id INT REFERENCES clientes(id),
  total NUMERIC(12,2) DEFAULT 0,
  fecha TIMESTAMPTZ DEFAULT now());          -- se guarda en UTC; la página la muestra en hora de Colombia

CREATE TABLE IF NOT EXISTS abonos (
  id SERIAL PRIMARY KEY,
  cliente_id INT NOT NULL REFERENCES clientes(id),
  monto NUMERIC(12,2) NOT NULL CHECK (monto > 0),
  fecha TIMESTAMPTZ DEFAULT now());

CREATE TABLE IF NOT EXISTS inventario_movimientos (
  id SERIAL PRIMARY KEY,
  producto_id INT NOT NULL REFERENCES productos(id),
  proveedor_id INT REFERENCES proveedores(id),
  tipo TEXT NOT NULL CHECK (tipo IN ('Compra','Ajuste')),
  cantidad INT NOT NULL,
  fecha TIMESTAMPTZ DEFAULT now());

CREATE TABLE IF NOT EXISTS venta_items (
  id SERIAL PRIMARY KEY,
  venta_id INT NOT NULL REFERENCES ventas(id),
  producto_id INT NOT NULL REFERENCES productos(id),
  cantidad INT NOT NULL CHECK (cantidad > 0),
  precio_unitario NUMERIC(12,2) NOT NULL,             -- precio de venta al público en el momento de la venta
  costo_unitario NUMERIC(12,2) NOT NULL DEFAULT 0);   -- precio unitario de compra en el momento de la venta

CREATE TABLE IF NOT EXISTS caja_movimientos (
  id SERIAL PRIMARY KEY,
  concepto TEXT NOT NULL,
  tipo TEXT CHECK (tipo IN ('Ingreso','Egreso')),
  monto NUMERIC(12,2) NOT NULL,
  fecha TIMESTAMPTZ DEFAULT now());

-- 2) PRODUCTOS: precio total de compra + unidades compradas (el precio unitario se calcula en la vista)
DO $$ BEGIN
  IF EXISTS (SELECT 1 FROM information_schema.columns
             WHERE table_schema = current_schema() AND table_name = 'productos' AND column_name = 'precio') THEN
    ALTER TABLE productos RENAME COLUMN precio TO precio_venta;
  END IF;
END $$;
ALTER TABLE productos DROP COLUMN IF EXISTS stock;
ALTER TABLE productos ADD COLUMN IF NOT EXISTS categoria_id INT REFERENCES categorias(id);
ALTER TABLE productos ADD COLUMN IF NOT EXISTS precio_venta NUMERIC(12,2) DEFAULT 0;
ALTER TABLE productos ADD COLUMN IF NOT EXISTS stock_minimo INT DEFAULT 5;
ALTER TABLE productos ADD COLUMN IF NOT EXISTS precio_total_compra NUMERIC(12,2) NOT NULL DEFAULT 0;
ALTER TABLE productos ADD COLUMN IF NOT EXISTS unidades_compra INT NOT NULL DEFAULT 1 CHECK (unidades_compra > 0);
DO $$ BEGIN
  IF EXISTS (SELECT 1 FROM information_schema.columns
             WHERE table_schema = current_schema() AND table_name = 'productos' AND column_name = 'precio_compra') THEN
    UPDATE productos SET precio_total_compra = COALESCE(precio_compra, 0);
    ALTER TABLE productos DROP COLUMN precio_compra;
  END IF;
END $$;

-- 3) INVENTARIO: precio total pagado + unidades (cantidad); el precio unitario se calcula en la vista
ALTER TABLE inventario_movimientos ADD COLUMN IF NOT EXISTS fecha_vencimiento DATE;
ALTER TABLE inventario_movimientos ADD COLUMN IF NOT EXISTS precio_total NUMERIC(12,2) NOT NULL DEFAULT 0;
DO $$ BEGIN
  IF EXISTS (SELECT 1 FROM information_schema.columns
             WHERE table_schema = current_schema() AND table_name = 'inventario_movimientos' AND column_name = 'costo_unitario') THEN
    UPDATE inventario_movimientos SET precio_total = COALESCE(costo_unitario, 0) * cantidad WHERE cantidad > 0;
    ALTER TABLE inventario_movimientos DROP COLUMN costo_unitario;
  END IF;
END $$;

-- 4) VENTAS: "debe" = lo que quedó fiado en esa venta (0 si pagó todo)
ALTER TABLE ventas ADD COLUMN IF NOT EXISTS debe NUMERIC(12,2) NOT NULL DEFAULT 0;
DO $$ BEGIN
  IF EXISTS (SELECT 1 FROM information_schema.columns
             WHERE table_schema = current_schema() AND table_name = 'ventas' AND column_name = 'tipo_pago') THEN
    UPDATE ventas SET debe = COALESCE(total, 0) WHERE tipo_pago = 'Crédito';
    ALTER TABLE ventas DROP CONSTRAINT IF EXISTS ventas_credito_requiere_cliente;
    ALTER TABLE ventas DROP COLUMN tipo_pago;
  END IF;
END $$;
ALTER TABLE ventas DROP CONSTRAINT IF EXISTS ventas_debe_valido;
ALTER TABLE ventas ADD CONSTRAINT ventas_debe_valido CHECK (debe >= 0 AND debe <= total);
ALTER TABLE ventas DROP CONSTRAINT IF EXISTS ventas_debe_requiere_cliente;
ALTER TABLE ventas ADD CONSTRAINT ventas_debe_requiere_cliente CHECK (debe = 0 OR cliente_id IS NOT NULL);

-- 5) CAJA: de dónde viene cada ingreso automático
ALTER TABLE caja_movimientos ADD COLUMN IF NOT EXISTS venta_id INT REFERENCES ventas(id);
ALTER TABLE caja_movimientos ADD COLUMN IF NOT EXISTS abono_id INT REFERENCES abonos(id);

-- Opcional: que el código de producto no se repita (los vacíos sí se permiten).
-- Descomenta solo si tus productos no tienen códigos repetidos.
-- CREATE UNIQUE INDEX IF NOT EXISTS uq_productos_codigo ON productos(codigo);

-- 6) Índices en las llaves foráneas
CREATE INDEX IF NOT EXISTS idx_productos_categoria ON productos(categoria_id);
CREATE INDEX IF NOT EXISTS idx_mov_producto        ON inventario_movimientos(producto_id);
CREATE INDEX IF NOT EXISTS idx_mov_proveedor       ON inventario_movimientos(proveedor_id);
CREATE INDEX IF NOT EXISTS idx_ventas_cliente      ON ventas(cliente_id);
CREATE INDEX IF NOT EXISTS idx_abonos_cliente      ON abonos(cliente_id);
CREATE INDEX IF NOT EXISTS idx_items_venta         ON venta_items(venta_id);
CREATE INDEX IF NOT EXISTS idx_items_producto      ON venta_items(producto_id);
CREATE INDEX IF NOT EXISTS idx_caja_venta          ON caja_movimientos(venta_id);
CREATE INDEX IF NOT EXISTS idx_caja_abono          ON caja_movimientos(abono_id);

-- 7) Datos iniciales
INSERT INTO categorias (nombre) VALUES ('Licores'),('Bebidas'),('Mecatos'),('Aseo'),('Otros')
  ON CONFLICT (nombre) DO NOTHING;

-- 8) Vistas (lo que lee la página)
CREATE VIEW v_categorias AS
  SELECT c.id, c.nombre, COUNT(p.id)::int AS productos
  FROM categorias c LEFT JOIN productos p ON p.categoria_id = c.id
  GROUP BY c.id, c.nombre;

-- Precio unitario de compra = precio total / unidades.  Ganancia = precio de venta - precio unitario de compra.
-- Stock = lo que entró por inventario - lo que salió por ventas.
CREATE VIEW v_productos AS
  SELECT b.*, (b.precio_venta - b.precio_compra) AS ganancia
  FROM (
    SELECT p.id, p.codigo, p.nombre, p.categoria_id, c.nombre AS categoria,
           p.precio_total_compra, p.unidades_compra,
           COALESCE(ROUND(p.precio_total_compra / NULLIF(p.unidades_compra, 0), 2), 0) AS precio_compra,
           p.precio_venta, p.stock_minimo,
           (COALESCE((SELECT SUM(m.cantidad) FROM inventario_movimientos m WHERE m.producto_id = p.id), 0)
            - COALESCE((SELECT SUM(i.cantidad) FROM venta_items i WHERE i.producto_id = p.id), 0))::int AS stock
    FROM productos p LEFT JOIN categorias c ON c.id = p.categoria_id
  ) b;

-- Precio unitario = precio total / unidades
CREATE VIEW v_inventario AS
  SELECT m.id, m.fecha, m.tipo, p.nombre AS producto, pr.empresa AS proveedor,
         m.cantidad, m.precio_total,
         CASE WHEN m.cantidad > 0 THEN ROUND(m.precio_total / m.cantidad, 2) ELSE 0 END AS costo_unitario,
         m.fecha_vencimiento::text AS fecha_vencimiento
  FROM inventario_movimientos m
  JOIN productos p ON p.id = m.producto_id
  LEFT JOIN proveedores pr ON pr.id = m.proveedor_id;

CREATE VIEW v_ventas AS
  SELECT v.id, v.fecha, v.cliente_id, c.nombre AS cliente, v.total, v.debe,
         COALESCE((SELECT SUM(i.cantidad) FROM venta_items i WHERE i.venta_id = v.id), 0)::int AS unidades,
         (SELECT string_agg(p.nombre || ' x' || i.cantidad, ', ' ORDER BY i.id)
          FROM venta_items i JOIN productos p ON p.id = i.producto_id WHERE i.venta_id = v.id) AS detalle
  FROM ventas v LEFT JOIN clientes c ON c.id = v.cliente_id;

-- Total de cada línea = cantidad x precio de venta al público
CREATE VIEW v_venta_items AS
  SELECT i.id, i.venta_id, v.fecha, c.nombre AS cliente, i.producto_id, p.nombre AS producto, i.cantidad,
         i.precio_unitario, i.costo_unitario,
         (i.cantidad * i.precio_unitario) AS subtotal,
         (i.cantidad * (i.precio_unitario - i.costo_unitario)) AS ganancia
  FROM venta_items i
  JOIN ventas v ON v.id = i.venta_id
  JOIN productos p ON p.id = i.producto_id
  LEFT JOIN clientes c ON c.id = v.cliente_id;

-- Deuda del cliente = lo que debe en sus ventas - sus abonos
CREATE VIEW v_clientes AS
  SELECT c.id, c.nombre, c.telefono, c.correo, c.creado,
         (COALESCE((SELECT SUM(v.debe) FROM ventas v WHERE v.cliente_id = c.id), 0)
          - COALESCE((SELECT SUM(a.monto) FROM abonos a WHERE a.cliente_id = c.id), 0)) AS deuda
  FROM clientes c;

-- Lotes con fecha de vencimiento y unidades que aún quedan de cada uno.
-- Se asume que lo que sale (ventas y ajustes negativos) consume primero el lote que vence antes.
-- dias_restantes: negativo = ya vencido (usa la fecha de Colombia).
CREATE VIEW v_lotes AS
  WITH entradas AS (
    SELECT m.id, m.producto_id, m.cantidad, m.fecha_vencimiento,
           SUM(m.cantidad) OVER (PARTITION BY m.producto_id
                                 ORDER BY m.fecha_vencimiento NULLS LAST, m.fecha, m.id) AS acumulado
    FROM inventario_movimientos m
    WHERE m.cantidad > 0
  ), salidas AS (
    SELECT p.id AS producto_id,
           COALESCE((SELECT SUM(i.cantidad) FROM venta_items i WHERE i.producto_id = p.id), 0)
           + COALESCE((SELECT -SUM(m.cantidad) FROM inventario_movimientos m
                       WHERE m.producto_id = p.id AND m.cantidad < 0), 0) AS total
    FROM productos p
  ), lotes AS (
    SELECT e.id, e.producto_id, e.fecha_vencimiento, e.cantidad AS cantidad_inicial,
           LEAST(e.cantidad, GREATEST(0, e.acumulado - s.total))::int AS restante
    FROM entradas e JOIN salidas s ON s.producto_id = e.producto_id
    WHERE e.fecha_vencimiento IS NOT NULL
  )
  SELECT l.id, l.producto_id, p.nombre AS producto, c.nombre AS categoria,
         l.fecha_vencimiento::text AS fecha_vencimiento, l.cantidad_inicial, l.restante,
         (l.fecha_vencimiento - (now() AT TIME ZONE 'America/Bogota')::date) AS dias_restantes
  FROM lotes l
  JOIN productos p ON p.id = l.producto_id
  LEFT JOIN categorias c ON c.id = p.categoria_id
  WHERE l.restante > 0;

-- 9) Verificación (opcional): ejecuta esto aparte; deben salir las 7 vistas y las llaves foráneas
-- SELECT table_name FROM information_schema.views WHERE table_schema = current_schema() ORDER BY 1;
-- SELECT conrelid::regclass AS tabla, conname, pg_get_constraintdef(oid) FROM pg_constraint WHERE contype = 'f' ORDER BY 1;
