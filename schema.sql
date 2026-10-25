-- Pega esto en Neon: SQL Editor -> Run
CREATE TABLE IF NOT EXISTS productos (
  id SERIAL PRIMARY KEY, codigo TEXT, nombre TEXT NOT NULL,
  stock INT DEFAULT 0, precio NUMERIC(12,2) DEFAULT 0, creado TIMESTAMPTZ DEFAULT now());
CREATE TABLE IF NOT EXISTS clientes (
  id SERIAL PRIMARY KEY, nombre TEXT NOT NULL, telefono TEXT, correo TEXT, creado TIMESTAMPTZ DEFAULT now());
CREATE TABLE IF NOT EXISTS proveedores (
  id SERIAL PRIMARY KEY, empresa TEXT NOT NULL, contacto TEXT, telefono TEXT, creado TIMESTAMPTZ DEFAULT now());
CREATE TABLE IF NOT EXISTS ventas (
  id SERIAL PRIMARY KEY, cliente_id INT REFERENCES clientes(id), total NUMERIC(12,2) DEFAULT 0, fecha TIMESTAMPTZ DEFAULT now());
CREATE TABLE IF NOT EXISTS caja_movimientos (
  id SERIAL PRIMARY KEY, concepto TEXT NOT NULL, tipo TEXT CHECK (tipo IN ('Ingreso','Egreso')),
  monto NUMERIC(12,2) NOT NULL, fecha TIMESTAMPTZ DEFAULT now());
