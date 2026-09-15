-- ============================================================================
-- FUUDELIVERY · MASTER SCHEMA v2.0
-- PostgreSQL 16 · Svelte + Bootstrap + PHP + Cloudflare
-- 12 FASES · 59 TELAS · CLIENTE, ENTREGADOR, LOJA E ADMIN
-- ============================================================================

-- EXTENSÕES NECESSÁRIAS
CREATE EXTENSION IF NOT EXISTS pgcrypto;   -- gen_random_uuid + criptografia
CREATE EXTENSION IF NOT EXISTS citext;     -- e-mail case-insensitive
CREATE EXTENSION IF NOT EXISTS pg_trgm;    -- busca fuzzy (trigram)
CREATE EXTENSION IF NOT EXISTS pg_cron;    -- jobs agendados no banco

-- ============================================================================
-- ENUMS GLOBAIS
-- ============================================================================
CREATE TYPE public.payment_method AS ENUM
  ('mp_card', 'pix_manual', 'cash', 'physical_machine', 'bitpay');

CREATE TYPE public.settlement_mode AS ENUM ('white_label', 'split');

CREATE TYPE public.order_status AS ENUM
  ('cart', 'pending_payment', 'pending_verification', 'paid',
   'preparing', 'ready', 'delivering', 'delivered',
   'rejected', 'cancelled', 'refunded');

CREATE TYPE public.onboarding_status AS ENUM
  ('submitted', 'under_review', 'docs_pending', 'approved', 'rejected');

CREATE TYPE public.risk_tier AS ENUM
  ('low', 'standard', 'high', 'blocked');

CREATE TYPE public.dispute_status AS ENUM
  ('open', 'under_review', 'resolved', 'escalated');

CREATE TYPE public.dispute_type AS ENUM
  ('item_missing', 'quality', 'late', 'chargeback_mp', 'chargeback_bitpay',
   'courier_unpaid', 'wrong_address', 'double_charge', 'fraud', 'other');

CREATE TYPE public.dispute_resolution AS ENUM
  ('full_refund', 'partial_refund', 'denied', 'reissued');

CREATE TYPE public.actor_role AS ENUM
  ('customer', 'restaurant', 'courier', 'platform', 'system', 'payment_provider');

-- ============================================================================
-- SCHEMA: ACCOUNT (USUÁRIOS E AUTENTICAÇÃO)
-- ============================================================================
CREATE SCHEMA IF NOT EXISTS account;

CREATE TABLE account.users (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  email citext UNIQUE,
  phone citext UNIQUE,
  password_hash text,  -- null para login OTP
  full_name text NOT NULL,
  role text NOT NULL DEFAULT 'customer' CHECK (role IN ('customer', 'restaurant', 'courier', 'admin')),
  is_active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX users_email_idx ON account.users USING btree (email);
CREATE INDEX users_phone_idx ON account.users USING btree (phone);

-- Tabela de OTP para login sem senha (Fase 10)
CREATE TABLE account.otp_codes (
  id bigserial PRIMARY KEY,
  user_id uuid REFERENCES account.users(id) ON DELETE CASCADE,
  code char(6) NOT NULL,
  purpose text NOT NULL CHECK (purpose IN ('login', 'phone_verify', 'email_verify')),
  expires_at timestamptz NOT NULL,
  consumed_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX otp_codes_user_idx ON account.otp_codes (user_id, created_at DESC);
CREATE INDEX otp_codes_code_idx ON account.otp_codes (code) WHERE consumed_at IS NULL;

-- Consentimentos LGPD (Fase 10)
CREATE TABLE account.lgpd_consents (
  id bigserial PRIMARY KEY,
  user_id uuid NOT NULL REFERENCES account.users(id) ON DELETE CASCADE,
  consent_type text NOT NULL CHECK (consent_type IN ('data_processing', 'marketing', 'location_tracking', 'proof_retention')),
  granted boolean NOT NULL,
  granted_at timestamptz NOT NULL DEFAULT now(),
  revoked_at timestamptz,
  ip inet,
  user_agent text
);

CREATE INDEX lgpd_consents_user_idx ON account.lgpd_consents (user_id);

-- ============================================================================
-- SCHEMA: RESTAURANT (LOJAS)
-- ============================================================================
CREATE SCHEMA IF NOT EXISTS restaurant;

CREATE TABLE restaurant.restaurants (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name text NOT NULL,
  trade_name text,
  cnpj char(14) UNIQUE CHECK (cnpj ~ '^[0-9]{14}$'),
  city_ibge_code char(7) NOT NULL,
  address jsonb NOT NULL DEFAULT '{}',
  phone citext,
  email citext,
  settlement settlement_mode NOT NULL DEFAULT 'white_label',
  platform_fee_bps int NOT NULL DEFAULT 0 CHECK (platform_fee_bps BETWEEN 0 AND 3000),
  pix_key text,
  accepting_orders boolean NOT NULL DEFAULT true,
  is_open boolean NOT NULL DEFAULT false,
  risk_tier risk_tier NOT NULL DEFAULT 'standard',
  deposit_required boolean NOT NULL DEFAULT false,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX restaurants_city_idx ON restaurant.restaurants (city_ibge_code);
CREATE INDEX restaurants_accepting_idx ON restaurant.restaurants (accepting_orders) WHERE accepting_orders = false;

-- Credenciais isoladas (Mercado Pago, BitPay) - NUNCA em SELECT * de restaurants
CREATE TABLE restaurant.restaurant_credentials (
  restaurant_id uuid PRIMARY KEY REFERENCES restaurant.restaurants(id) ON DELETE CASCADE,
  mp_public_key text,
  mp_access_token bytea,          -- pgp_sym_encrypt(token, :key)
  mp_collector_id text,
  bitpay_token bytea,
  rotated_at timestamptz NOT NULL DEFAULT now()
);

-- Horário de funcionamento semanal (Fase 11.4)
CREATE TABLE restaurant.operating_hours (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  restaurant_id uuid NOT NULL REFERENCES restaurant.restaurants(id) ON DELETE CASCADE,
  weekday int NOT NULL CHECK (weekday BETWEEN 0 AND 6),  -- 0=Domingo, 6=Sábado
  open_time time NOT NULL,
  close_time time NOT NULL,
  is_closed boolean NOT NULL DEFAULT false,
  UNIQUE (restaurant_id, weekday)
);

-- Feriados / datas especiais (Fase 11.4)
CREATE TABLE restaurant.special_hours (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  restaurant_id uuid NOT NULL REFERENCES restaurant.restaurants(id) ON DELETE CASCADE,
  on_date date NOT NULL,
  open_time time,
  close_time time,
  is_closed boolean NOT NULL DEFAULT false,
  reason text,
  UNIQUE (restaurant_id, on_date)
);

-- Pausas registradas (ato com autor e motivo) - Fase 11.3
CREATE TABLE restaurant.store_pauses (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  restaurant_id uuid NOT NULL REFERENCES restaurant.restaurants(id) ON DELETE CASCADE,
  paused_by uuid NOT NULL REFERENCES account.users(id),
  reason text NOT NULL CHECK (length(trim(reason)) >= 3),
  paused_at timestamptz NOT NULL DEFAULT now(),
  resume_at timestamptz,
  resumed_at timestamptz,
  active boolean NOT NULL DEFAULT true
);

CREATE INDEX store_pauses_active_idx ON restaurant.store_pauses (restaurant_id, active) WHERE active = true;

-- ============================================================================
-- SCHEMA: CATALOG (CARDÁPIO)
-- ============================================================================
CREATE SCHEMA IF NOT EXISTS catalog;

CREATE TABLE catalog.categories (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  restaurant_id uuid NOT NULL REFERENCES restaurant.restaurants(id) ON DELETE CASCADE,
  name text NOT NULL,
  description text,
  sort_order int NOT NULL DEFAULT 0,
  is_active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX categories_restaurant_idx ON catalog.categories (restaurant_id, sort_order);

CREATE TABLE catalog.products (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  restaurant_id uuid NOT NULL REFERENCES restaurant.restaurants(id) ON DELETE CASCADE,
  category_id uuid REFERENCES catalog.categories(id) ON DELETE SET NULL,
  name text NOT NULL,
  description text,
  price numeric(12,2) NOT NULL CHECK (price >= 0),
  photo_storage_key text,
  is_available boolean NOT NULL DEFAULT true,
  sort_order int NOT NULL DEFAULT 0,
  calories int,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX products_restaurant_idx ON catalog.products (restaurant_id, is_available);
CREATE INDEX products_name_trgm ON catalog.products USING gin (name gin_trgm_ops);

-- Extras/opcionais do produto
CREATE TABLE catalog.product_extras (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  product_id uuid NOT NULL REFERENCES catalog.products(id) ON DELETE CASCADE,
  name text NOT NULL,
  price numeric(12,2) NOT NULL CHECK (price >= 0),
  max_quantity int DEFAULT 1,
  is_required boolean NOT NULL DEFAULT false,
  sort_order int NOT NULL DEFAULT 0
);

CREATE INDEX product_extras_product_idx ON catalog.product_extras (product_id);

-- ============================================================================
-- SCHEMA: SALES (PEDIDOS)
-- ============================================================================
CREATE SCHEMA IF NOT EXISTS sales;

CREATE TABLE sales.orders (
  id bigserial PRIMARY KEY,
  public_code text NOT NULL UNIQUE DEFAULT upper(substr(encode(gen_random_bytes(4), 'hex'), 1, 8)),
  user_id uuid NOT NULL REFERENCES account.users(id),
  restaurant_id uuid NOT NULL REFERENCES restaurant.restaurants(id),
  status order_status NOT NULL DEFAULT 'cart',
  subtotal numeric(12,2) NOT NULL CHECK (subtotal >= 0),
  delivery_fee numeric(12,2) NOT NULL DEFAULT 0,
  discount numeric(12,2) NOT NULL DEFAULT 0,
  total numeric(12,2) GENERATED ALWAYS AS (subtotal + delivery_fee - discount) STORED,
  payment_method payment_method,
  change_for numeric(12,2) CHECK (change_for IS NULL OR change_for >= 0),
  machine_type text CHECK (machine_type IN ('debit', 'credit')),
  delivery_address jsonb NOT NULL DEFAULT '{}',
  verification_deadline timestamptz,
  accepted_at timestamptz,
  delivered_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  
  CONSTRAINT cash_change_valid CHECK (
    payment_method <> 'cash' OR change_for IS NULL OR change_for >= subtotal),
  CONSTRAINT machine_needs_type CHECK (
    payment_method <> 'physical_machine' OR machine_type IS NOT NULL)
);

CREATE INDEX orders_kds_idx ON sales.orders (restaurant_id, created_at DESC)
  WHERE status IN ('paid', 'preparing', 'ready');
CREATE INDEX orders_awaiting_idx ON sales.orders (verification_deadline)
  WHERE status = 'pending_verification';
CREATE INDEX orders_user_idx ON sales.orders (user_id, created_at DESC);
CREATE INDEX orders_status_idx ON sales.orders (status);

-- Itens do pedido (snapshot do produto no momento da compra)
CREATE TABLE sales.order_items (
  id bigserial PRIMARY KEY,
  order_id bigint NOT NULL REFERENCES sales.orders(id) ON DELETE CASCADE,
  product_id uuid,
  product_snapshot jsonb NOT NULL DEFAULT '{}',  -- nome, preço, foto no momento da compra
  quantity int NOT NULL CHECK (quantity > 0),
  unit_price numeric(12,2) NOT NULL CHECK (unit_price >= 0),
  extras_snapshot jsonb NOT NULL DEFAULT '[]',
  observation text,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX order_items_order_idx ON sales.order_items (order_id);

-- Linha do tempo do pedido (append-only) - Fase 11.A
CREATE TABLE sales.order_events (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  order_id bigint NOT NULL REFERENCES sales.orders(id) ON DELETE CASCADE,
  from_status order_status,
  to_status order_status NOT NULL,
  actor_user_id uuid REFERENCES account.users(id),
  actor_role actor_role,
  note text,
  geo point,
  ip inet,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX order_events_order_idx ON sales.order_events (order_id, created_at);

-- ============================================================================
-- SCHEMA: PAY (PAGAMENTOS)
-- ============================================================================
CREATE SCHEMA IF NOT EXISTS pay;

CREATE TABLE pay.payments (
  id bigserial PRIMARY KEY,
  order_id bigint NOT NULL REFERENCES sales.orders(id) ON DELETE CASCADE,
  provider text NOT NULL CHECK (provider IN ('mercadopago', 'bitpay', 'offline')),
  provider_ref text,
  amount numeric(12,2) NOT NULL CHECK (amount > 0),
  platform_fee numeric(12,2) NOT NULL DEFAULT 0,
  status text NOT NULL CHECK (status IN
    ('created', 'in_process', 'approved', 'rejected', 'refunded', 'charged_back')),
  status_detail text,
  raw_response jsonb,          -- resposta crua: prova em disputa
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (provider, provider_ref)
);

-- Regra de ouro: no máximo UM pagamento aprovado por pedido
CREATE UNIQUE INDEX payments_one_approved ON pay.payments (order_id)
  WHERE status = 'approved';

CREATE INDEX payments_order_idx ON pay.payments (order_id);
CREATE INDEX payments_status_idx ON pay.payments (status);

-- Comprovantes de pagamento (Pix manual, dinheiro)
CREATE TABLE pay.payment_proofs (
  id bigserial PRIMARY KEY,
  order_id bigint NOT NULL REFERENCES sales.orders(id) ON DELETE CASCADE,
  storage_key text NOT NULL,             -- bucket privado (R2/S3), nunca webroot
  sha256 char(64) NOT NULL,
  phash bigint,                    -- detecta reuso de print (perceptual hash)
  bytes int NOT NULL CHECK (bytes <= 2097152),
  mime text NOT NULL CHECK (mime IN ('image/jpeg', 'image/png', 'image/webp')),
  uploaded_ip inet NOT NULL,
  review text NOT NULL DEFAULT 'pending'
    CHECK (review IN ('pending', 'approved', 'rejected')),
  reviewed_by uuid REFERENCES account.users(id),
  reviewed_at timestamptz,
  reject_reason text,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX proofs_reuse_idx ON pay.payment_proofs (sha256);
CREATE INDEX proofs_order_idx ON pay.payment_proofs (order_id);
CREATE INDEX proofs_pending_idx ON pay.payment_proofs (review) WHERE review = 'pending';

-- ============================================================================
-- SCHEMA: FINANCE (LEDGER APPEND-ONLY - FASE 9)
-- ============================================================================
CREATE SCHEMA IF NOT EXISTS finance;

-- Tipo de conta no ledger
CREATE TYPE public.account_type AS ENUM
  ('platform_receivable', 'platform_payable', 'restaurant_receivable',
   'restaurant_payable', 'courier_receivable', 'courier_payable',
   'customer_receivable', 'customer_payable');

-- Tipo de lançamento
CREATE TYPE public.entry_type AS ENUM
  ('sale', 'fee', 'freight_charge', 'freight_payout', 'refund_contraparty',
   'chargeback', 'deposit', 'withdrawal', 'adjustment');

CREATE TABLE finance.ledger_entries (
  id bigserial PRIMARY KEY,
  account_type account_type NOT NULL,
  account_ref uuid NOT NULL,  -- restaurant_id, courier_id, etc.
  order_id bigint REFERENCES sales.orders(id),
  dispute_id uuid,
  entry_type entry_type NOT NULL,
  amount numeric(12,2) NOT NULL,  -- positivo = crédito, negativo = débito
  origin text NOT NULL,           -- 'checkout', 'dispute_resolution', 'webhook', etc.
  created_by uuid REFERENCES account.users(id),
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX ledger_entries_account_idx ON finance.ledger_entries (account_type, account_ref);
CREATE INDEX ledger_entries_order_idx ON finance.ledger_entries (order_id);
CREATE INDEX ledger_entries_dispute_idx ON finance.ledger_entries (dispute_id);

-- Freight due por loja (para cálculo de netting)
CREATE TABLE finance.store_freight (
  id bigserial PRIMARY KEY,
  restaurant_id uuid NOT NULL REFERENCES restaurant.restaurants(id),
  day date NOT NULL,
  freight_due numeric(12,2) NOT NULL DEFAULT 0,
  UNIQUE (restaurant_id, day)
);

-- ============================================================================
-- SCHEMA: ADMIN (PLATAFORMA - FASE 12)
-- ============================================================================
CREATE SCHEMA IF NOT EXISTS admin;

-- Onboarding de lojas (Fase 12.2)
CREATE TABLE admin.store_onboarding (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  restaurant_id uuid REFERENCES restaurant.restaurants(id) ON DELETE SET NULL,
  legal_name text NOT NULL,
  trade_name text NOT NULL,
  cnpj char(14) NOT NULL UNIQUE CHECK (cnpj ~ '^[0-9]{14}$'),
  city_ibge_code char(7),
  owner_user_id uuid REFERENCES account.users(id),
  docs jsonb NOT NULL DEFAULT '{}',
  status onboarding_status NOT NULL DEFAULT 'submitted',
  risk_tier risk_tier NOT NULL DEFAULT 'standard',
  deposit_required boolean NOT NULL DEFAULT false,
  proposed_fee_percent numeric(5,2) CHECK (proposed_fee_percent BETWEEN 0 AND 100),
  reviewed_by uuid REFERENCES account.users(id),
  review_note text,
  submitted_at timestamptz NOT NULL DEFAULT now(),
  reviewed_at timestamptz
);

CREATE INDEX store_onboarding_status_idx ON admin.store_onboarding (status)
  WHERE status IN ('submitted', 'under_review', 'docs_pending');

-- Disputas (cliente, entregador, loja, chargeback) - Fase 12.4/12.5
CREATE TABLE admin.disputes (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  order_id bigint NOT NULL REFERENCES sales.orders(id),
  opened_by uuid REFERENCES account.users(id),
  opened_by_role actor_role NOT NULL,
  type dispute_type NOT NULL,
  status dispute_status NOT NULL DEFAULT 'open',
  reason text NOT NULL,
  amount_disputed numeric(12,2) CHECK (amount_disputed >= 0),
  evidence jsonb NOT NULL DEFAULT '[]',
  resolution dispute_resolution,
  refund_amount numeric(12,2) CHECK (refund_amount >= 0),
  resolved_by uuid REFERENCES account.users(id),
  resolution_note text,
  opened_at timestamptz NOT NULL DEFAULT now(),
  resolved_at timestamptz
);

CREATE INDEX disputes_open_idx ON admin.disputes (opened_at)
  WHERE status IN ('open', 'under_review');
CREATE INDEX disputes_order_idx ON admin.disputes (order_id);

-- Galeria antifraude (Fase 12.6)
CREATE SCHEMA IF NOT EXISTS risk;

CREATE TABLE risk.fraud_events (
  id bigserial PRIMARY KEY,
  event_type text NOT NULL CHECK (event_type IN (
    'proof_rejected', 'duplicate_sha256', 'duplicate_phash',
    'user_blocked', 'store_flagged', 'velocity_alert', 'geo_mismatch')),
  entity_type text NOT NULL CHECK (entity_type IN ('user', 'restaurant', 'order', 'proof')),
  entity_id uuid NOT NULL,
  details jsonb NOT NULL DEFAULT '{}',
  action_taken text,
  expires_at timestamptz,  -- LGPD: expurgo após 180 dias
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX fraud_events_entity_idx ON risk.fraud_events (entity_type, entity_id);
CREATE INDEX fraud_events_expires_idx ON risk.fraud_events (expires_at) WHERE expires_at IS NOT NULL;

-- ============================================================================
-- SCHEMA: DELIVERY (ENTREGADORES - FASE 8)
-- ============================================================================
CREATE SCHEMA IF NOT EXISTS delivery;

CREATE TABLE delivery.couriers (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES account.users(id) ON DELETE CASCADE,
  vehicle_type text CHECK (vehicle_type IN ('bike', 'motorcycle', 'car')),
  license_plate text,
  is_available boolean NOT NULL DEFAULT false,
  current_lat numeric(9,6),
  current_lng numeric(9,6),
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX couriers_available_idx ON delivery.couriers (is_available) WHERE is_available = true;

-- Despacho de pedidos para entregadores
CREATE TABLE delivery.dispatches (
  id bigserial PRIMARY KEY,
  order_id bigint NOT NULL REFERENCES sales.orders(id),
  courier_id uuid REFERENCES delivery.couriers(id),
  status text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'accepted', 'picked_up', 'delivered', 'failed')),
  offered_at timestamptz NOT NULL DEFAULT now(),
  accepted_at timestamptz,
  picked_up_at timestamptz,
  delivered_at timestamptz,
  failure_reason text
);

CREATE INDEX dispatches_order_idx ON delivery.dispatches (order_id);
CREATE INDEX dispatches_courier_idx ON delivery.dispatches (courier_id, status);
CREATE INDEX dispatches_pending_idx ON delivery.dispatches (status) WHERE status = 'pending';

-- ============================================================================
-- INFRAESTRUTURA: OUTBOX E IDEMPOTÊNCIA
-- ============================================================================

-- Outbox pattern para eventos só existirem se a transação commitou
CREATE TABLE public.outbox (
  id bigserial PRIMARY KEY,
  topic text NOT NULL,
  payload jsonb NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  sent_at timestamptz
);

CREATE INDEX outbox_pending ON public.outbox (id) WHERE sent_at IS NULL;

-- Chaves de idempotência para evitar duplicidade de requisições
CREATE TABLE public.idempotency_keys (
  key uuid PRIMARY KEY,
  endpoint text NOT NULL,
  request_hash char(64) NOT NULL,
  state text NOT NULL DEFAULT 'in_flight'
    CHECK (state IN ('in_flight', 'done')),
  response jsonb,
  created_at timestamptz NOT NULL DEFAULT now()
);

-- ============================================================================
-- FUNÇÕES E TRIGGERS
-- ============================================================================

-- Função advance_order(): motor do KDS (Fase 11.B)
CREATE OR REPLACE FUNCTION sales.advance_order(
  p_order_id bigint,
  p_to order_status,
  p_actor uuid,
  p_actor_role actor_role DEFAULT 'restaurant',
  p_note text DEFAULT NULL
)
RETURNS sales.orders
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, sales, pay, account
AS $$
DECLARE
  v_order sales.orders;
  v_old order_status;
BEGIN
  SELECT * INTO v_order FROM sales.orders WHERE id = p_order_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Pedido não encontrado';
  END IF;

  v_old := v_order.status;

  -- Atualiza o status do pedido
  UPDATE sales.orders
     SET status       = p_to,
         accepted_at  = CASE WHEN p_to = 'preparing' AND accepted_at IS NULL THEN now() ELSE accepted_at END,
         delivered_at = CASE WHEN p_to = 'delivered' THEN now() ELSE delivered_at END,
         updated_at   = now()
   WHERE id = p_order_id
   RETURNING * INTO v_order;

  -- Grava o evento na linha do tempo
  INSERT INTO sales.order_events (order_id, from_status, to_status, actor_user_id, actor_role, note)
  VALUES (p_order_id, v_old, p_to, p_actor, p_actor_role, p_note);

  -- Notifica em tempo real o KDS e o despacho via LISTEN/NOTIFY
  PERFORM pg_notify('kds_' || v_order.restaurant_id::text,
                    json_build_object('order_id', p_order_id, 'to', p_to)::text);
  PERFORM pg_notify('dispatch_' || v_order.restaurant_id::text,
                    json_build_object('order_id', p_order_id, 'to', p_to)::text);

  RETURN v_order;
END;
$$;

-- Trigger para validar transições de status
CREATE OR REPLACE FUNCTION sales.check_order_transition()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, sales
AS $$
BEGIN
  -- Valida transições permitidas
  IF TG_OP = 'UPDATE' THEN
    IF OLD.status = 'cart' AND NEW.status NOT IN ('pending_payment', 'cancelled') THEN
      RAISE EXCEPTION 'Transição inválida de cart';
    END IF;
    IF OLD.status = 'pending_payment' AND NEW.status NOT IN ('pending_verification', 'cancelled') THEN
      RAISE EXCEPTION 'Transição inválida de pending_payment';
    END IF;
    IF OLD.status = 'pending_verification' AND NEW.status NOT IN ('paid', 'rejected', 'cancelled') THEN
      RAISE EXCEPTION 'Transição inválida de pending_verification';
    END IF;
    IF OLD.status = 'paid' AND NEW.status NOT IN ('preparing') THEN
      RAISE EXCEPTION 'Transição inválida de paid';
    END IF;
    IF OLD.status = 'preparing' AND NEW.status NOT IN ('ready') THEN
      RAISE EXCEPTION 'Transição inválida de preparing';
    END IF;
    IF OLD.status = 'ready' AND NEW.status NOT IN ('delivering') THEN
      RAISE EXCEPTION 'Transição inválida de ready';
    END IF;
    IF OLD.status = 'delivering' AND NEW.status NOT IN ('delivered') THEN
      RAISE EXCEPTION 'Transição inválida de delivering';
    END IF;
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER trg_check_order_transition
  BEFORE UPDATE ON sales.orders
  FOR EACH ROW
  EXECUTE FUNCTION sales.check_order_transition();

-- Trigger para atualizar updated_at
CREATE OR REPLACE FUNCTION public.update_updated_at_column()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$;

CREATE TRIGGER trg_users_updated_at
  BEFORE UPDATE ON account.users
  FOR EACH ROW
  EXECUTE FUNCTION public.update_updated_at_column();

CREATE TRIGGER trg_restaurants_updated_at
  BEFORE UPDATE ON restaurant.restaurants
  FOR EACH ROW
  EXECUTE FUNCTION public.update_updated_at_column();

CREATE TRIGGER trg_products_updated_at
  BEFORE UPDATE ON catalog.products
  FOR EACH ROW
  EXECUTE FUNCTION public.update_updated_at_column();

CREATE TRIGGER trg_orders_updated_at
  BEFORE UPDATE ON sales.orders
  FOR EACH ROW
  EXECUTE FUNCTION public.update_updated_at_column();

-- ============================================================================
-- ROW LEVEL SECURITY (RLS) - SEGURANÇA POR PAPEL
-- ============================================================================

-- Funções auxiliares para RLS
CREATE OR REPLACE FUNCTION auth.is_admin()
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public AS $$
  SELECT nullif(current_setting('app.role', true), '') = 'admin';
$$;

CREATE OR REPLACE FUNCTION auth.is_restaurant(p_restaurant uuid)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, restaurant AS $$
  SELECT auth.is_admin()
     OR (nullif(current_setting('app.restaurant_id', true), '')::uuid = p_restaurant);
$$;

CREATE OR REPLACE FUNCTION auth.is_owner(p_user_id uuid)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public AS $$
  SELECT auth.is_admin()
     OR (nullif(current_setting('app.user_id', true), '')::uuid = p_user_id);
$$;

-- Habilitar RLS nas tabelas críticas
ALTER TABLE catalog.products ENABLE ROW LEVEL SECURITY;
ALTER TABLE sales.orders ENABLE ROW LEVEL SECURITY;
ALTER TABLE pay.payment_proofs ENABLE ROW LEVEL SECURITY;

-- Políticas para produtos (loja vê apenas os seus, admin vê tudo)
CREATE POLICY products_select ON catalog.products
  FOR SELECT USING (auth.is_restaurant(restaurant_id));

CREATE POLICY products_write ON catalog.products
  FOR ALL USING (auth.is_restaurant(restaurant_id));

-- Políticas para pedidos (cliente vê os seus, restaurante vê os da sua loja, admin vê tudo)
CREATE POLICY orders_select ON sales.orders
  FOR SELECT USING (
    auth.is_owner(user_id) OR
    auth.is_restaurant(restaurant_id)
  );

-- Políticas para comprovantes (restaurante vê os da sua loja, admin vê tudo)
CREATE POLICY proofs_select ON pay.payment_proofs
  FOR SELECT USING (
    EXISTS (
      SELECT 1 FROM sales.orders o
      WHERE o.id = payment_proofs.order_id
        AND auth.is_restaurant(o.restaurant_id)
    )
  );

CREATE POLICY proofs_approve ON pay.payment_proofs
  FOR UPDATE USING (
    EXISTS (
      SELECT 1 FROM sales.orders o
      WHERE o.id = payment_proofs.order_id
        AND auth.is_restaurant(o.restaurant_id)
    )
  );

-- ============================================================================
-- MATERIALIZED VIEWS PARA RELATÓRIOS (FASE 12.7)
-- ============================================================================

-- GMV diário da plataforma
CREATE MATERIALIZED VIEW admin.mv_daily_gmv AS
SELECT
  date_trunc('day', o.created_at)::date AS day,
  o.restaurant_id,
  COUNT(*) FILTER (WHERE o.status IN ('paid', 'preparing', 'ready', 'delivering', 'delivered')) AS orders_count,
  SUM(o.total) FILTER (WHERE o.status = 'delivered') AS gmv_delivered,
  SUM(p.platform_fee) FILTER (WHERE p.status = 'approved') AS platform_fee
FROM sales.orders o
LEFT JOIN pay.payments p ON p.order_id = o.id AND p.status = 'approved'
GROUP BY 1, 2;

CREATE UNIQUE INDEX mv_daily_gmv_idx ON admin.mv_daily_gmv (day, restaurant_id);

-- Netting semanal por loja
CREATE MATERIALIZED VIEW admin.mv_store_netting AS
SELECT
  restaurant_id,
  SUM(gmv_delivered) AS gmv,
  SUM(platform_fee) AS fee,
  COALESCE(SUM(f.freight_due), 0) AS freight_to_us,
  SUM(gmv_delivered) - SUM(platform_fee) + COALESCE(SUM(f.freight_due), 0) AS to_collect
FROM admin.mv_daily_gmv d
LEFT JOIN finance.store_freight f USING (restaurant_id, day)
GROUP BY 1;

CREATE UNIQUE INDEX mv_store_netting_idx ON admin.mv_store_netting (restaurant_id);

-- ============================================================================
-- JOB AGENDADO: EXPURGO DE DADOS LGPD (180 DIAS)
-- ============================================================================

-- Job para expirar eventos de fraude após 180 dias (LGPD)
SELECT cron.schedule(
  'fraud_events_expunge',
  '0 3 * * *',  -- Todo dia às 03:00
  $$DELETE FROM risk.fraud_events WHERE expires_at < now()$$
);

-- Job para cancelar pedidos pendentes de verificação após prazo
SELECT cron.schedule(
  'cancel_expired_orders',
  '*/5 * * * *',  -- A cada 5 minutos
  $$SELECT sales.advance_order(id, 'cancelled', NULL, 'system', 'Tempo de verificação expirado')
    FROM sales.orders
    WHERE status = 'pending_verification'
      AND verification_deadline < now()$$
);

-- ============================================================================
-- COMENTÁRIOS E DOCUMENTAÇÃO
-- ============================================================================

COMMENT ON SCHEMA account IS 'Usuários e autenticação (OTP, LGPD)';
COMMENT ON SCHEMA restaurant IS 'Lojas, credenciais, horários e pausas';
COMMENT ON SCHEMA catalog IS 'Cardápio: categorias, produtos e extras';
COMMENT ON SCHEMA sales IS 'Pedidos e linha do tempo (order_events)';
COMMENT ON SCHEMA pay IS 'Pagamentos, comprovantes e integrações';
COMMENT ON SCHEMA finance IS 'Ledger append-only para conciliação financeira';
COMMENT ON SCHEMA admin IS 'Onboarding, disputas e governança da plataforma';
COMMENT ON SCHEMA risk IS 'Antifraude e eventos de risco';
COMMENT ON SCHEMA delivery IS 'Entregadores e despacho';

COMMENT ON FUNCTION sales.advance_order IS 'Motor do KDS: transiciona pedido, grava evento e notifica em tempo real';
COMMENT ON TABLE sales.order_events IS 'Linha do tempo append-only do pedido - fonte única para tracking, disputa e auditoria';
COMMENT ON TABLE finance.ledger_entries IS 'Livro contábil append-only - saldos são SUM(), correções são contrapartidas';
COMMENT ON TABLE risk.fraud_events IS 'Eventos de fraude com expiração automática (LGPD 180 dias)';

-- ============================================================================
-- FIM DO SCHEMA MASTER
-- ============================================================================
