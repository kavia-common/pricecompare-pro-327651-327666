#!/bin/bash
set -euo pipefail

# Idempotent schema initialization + seed data for the PriceCompare app.
# This script is designed to be safe to run multiple times.

DB_NAME="${DB_NAME:-myapp}"
DB_USER="${DB_USER:-appuser}"
DB_PASSWORD="${DB_PASSWORD:-dbuser123}"
DB_PORT="${DB_PORT:-5000}"

# Prefer reading the connection string from db_connection.txt (per container rules),
# but fall back to constructing it from environment variables.
CONN_STR=""
if [ -f "db_connection.txt" ]; then
  # Expected format: psql postgresql://user:pass@host:port/db
  CONN_STR="$(cat db_connection.txt | sed 's/^psql[[:space:]]*//')"
else
  CONN_STR="postgresql://${DB_USER}:${DB_PASSWORD}@localhost:${DB_PORT}/${DB_NAME}"
fi

PSQL_BASE=(psql "${CONN_STR}" -v ON_ERROR_STOP=1)

echo "SchemaInitFlow: starting schema initialization + seed"
echo "SchemaInitFlow: using connection: ${CONN_STR}"

# --- Schema (tables) ----------------------------------------------------------

# queries: a persisted user search or URL submission
"${PSQL_BASE[@]}" -c "
CREATE TABLE IF NOT EXISTS public.queries (
  id BIGSERIAL PRIMARY KEY,
  query_text TEXT NULL,
  query_url TEXT NULL,
  query_type TEXT NOT NULL DEFAULT 'text',
  status TEXT NOT NULL DEFAULT 'completed',
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT queries_query_type_chk CHECK (query_type IN ('text','url')),
  CONSTRAINT queries_nonempty_chk CHECK (
    (query_text IS NOT NULL AND btrim(query_text) <> '') OR
    (query_url IS NOT NULL AND btrim(query_url) <> '')
  )
);
"

"${PSQL_BASE[@]}" -c "
CREATE INDEX IF NOT EXISTS idx_queries_created_at ON public.queries(created_at DESC);
"

# sites: supported e-commerce sites
"${PSQL_BASE[@]}" -c "
CREATE TABLE IF NOT EXISTS public.sites (
  id BIGSERIAL PRIMARY KEY,
  code TEXT NOT NULL UNIQUE,
  name TEXT NOT NULL,
  base_url TEXT NOT NULL,
  enabled BOOLEAN NOT NULL DEFAULT TRUE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
"

# parsers: configuration for how to scrape/parse a site (lightweight, configurable)
"${PSQL_BASE[@]}" -c "
CREATE TABLE IF NOT EXISTS public.parsers (
  id BIGSERIAL PRIMARY KEY,
  site_id BIGINT NOT NULL REFERENCES public.sites(id) ON DELETE CASCADE,
  parser_name TEXT NOT NULL,
  version TEXT NOT NULL DEFAULT '1.0',
  config JSONB NOT NULL DEFAULT '{}'::jsonb,
  enabled BOOLEAN NOT NULL DEFAULT TRUE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT parsers_site_parser_unique UNIQUE (site_id, parser_name, version)
);
"

"${PSQL_BASE[@]}" -c "
CREATE INDEX IF NOT EXISTS idx_parsers_site_enabled ON public.parsers(site_id, enabled);
"

# offers: results returned per query per site listing
"${PSQL_BASE[@]}" -c "
CREATE TABLE IF NOT EXISTS public.offers (
  id BIGSERIAL PRIMARY KEY,
  query_id BIGINT NOT NULL REFERENCES public.queries(id) ON DELETE CASCADE,
  site_id BIGINT NOT NULL REFERENCES public.sites(id) ON DELETE RESTRICT,
  parser_id BIGINT NULL REFERENCES public.parsers(id) ON DELETE SET NULL,

  product_name TEXT NULL,
  product_url TEXT NOT NULL,
  image_url TEXT NULL,
  currency TEXT NOT NULL DEFAULT 'INR',

  price_numeric NUMERIC(12,2) NULL,
  price_text TEXT NULL,

  availability TEXT NULL,
  shipping_text TEXT NULL,

  raw_data JSONB NOT NULL DEFAULT '{}'::jsonb,
  scraped_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),

  CONSTRAINT offers_url_nonempty_chk CHECK (btrim(product_url) <> '')
);
"

"${PSQL_BASE[@]}" -c "
CREATE INDEX IF NOT EXISTS idx_offers_query_id ON public.offers(query_id);
"
"${PSQL_BASE[@]}" -c "
CREATE INDEX IF NOT EXISTS idx_offers_site_id ON public.offers(site_id);
"
"${PSQL_BASE[@]}" -c "
CREATE INDEX IF NOT EXISTS idx_offers_scraped_at ON public.offers(scraped_at DESC);
"

# price_history: track price changes over time for the same offer URL+site
"${PSQL_BASE[@]}" -c "
CREATE TABLE IF NOT EXISTS public.price_history (
  id BIGSERIAL PRIMARY KEY,
  site_id BIGINT NOT NULL REFERENCES public.sites(id) ON DELETE RESTRICT,
  product_url TEXT NOT NULL,
  price_numeric NUMERIC(12,2) NULL,
  currency TEXT NOT NULL DEFAULT 'INR',
  observed_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  query_id BIGINT NULL REFERENCES public.queries(id) ON DELETE SET NULL,
  offer_id BIGINT NULL REFERENCES public.offers(id) ON DELETE SET NULL,

  CONSTRAINT price_history_url_nonempty_chk CHECK (btrim(product_url) <> '')
);
"

"${PSQL_BASE[@]}" -c "
CREATE INDEX IF NOT EXISTS idx_price_history_lookup ON public.price_history(site_id, product_url, observed_at DESC);
"

# --- Seed data (supported sites + minimal parser configs) ----------------------

# Target sites: gameloot.in, gamestheshop.com, gamenation.in, amazon.com, flipkart.com
"${PSQL_BASE[@]}" -c "
INSERT INTO public.sites (code, name, base_url, enabled)
VALUES
  ('gameloot', 'Gameloot', 'https://gameloot.in', TRUE),
  ('gamestheshop', 'Games The Shop', 'https://www.gamestheshop.com', TRUE),
  ('gamenation', 'GameNation', 'https://gamenation.in', TRUE),
  ('amazon', 'Amazon', 'https://www.amazon.com', TRUE),
  ('flipkart', 'Flipkart', 'https://www.flipkart.com', TRUE)
ON CONFLICT (code) DO UPDATE
SET
  name = EXCLUDED.name,
  base_url = EXCLUDED.base_url,
  enabled = EXCLUDED.enabled,
  updated_at = now();
"

# Minimal parser config seed. Keep it simple but extensible via JSONB.
# NOTE: these are placeholders for the backend scraper registry; config is
# intended to be used by the backend (selectors, rate limits, etc).
"${PSQL_BASE[@]}" -c "
INSERT INTO public.parsers (site_id, parser_name, version, config, enabled)
SELECT s.id, 'default', '1.0',
  jsonb_build_object(
    'notes', 'Seed default parser config. Backend may override/extend.',
    'rate_limit_per_min', 30,
    'user_agent', 'PriceCompareBot/1.0',
    'selectors', jsonb_build_object()
  ),
  TRUE
FROM public.sites s
WHERE s.code IN ('gameloot','gamestheshop','gamenation','amazon','flipkart')
ON CONFLICT (site_id, parser_name, version) DO UPDATE
SET
  config = EXCLUDED.config,
  enabled = EXCLUDED.enabled,
  updated_at = now();
"

echo "SchemaInitFlow: completed successfully"
