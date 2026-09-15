-- FUUDELIVERY · SEED DATA (Dados de Teste)
-- Executar após o schema principal para popular com dados demo
-- 
-- Uso: psql -U fuud_admin_prod -d fuudelivery_prod -f db/seeds/01-demo-data.sql

-- ============================================================================
-- USUÁRIOS DEMO
-- ============================================================================

-- Admin da plataforma
INSERT INTO account.users (email, password_hash, full_name, role, is_active)
VALUES (
  'admin@fuudelivery.com',
  '$2y$10$92IXUNpkjO0rOQ5byMi.Ye4oKoEa3Ro9llC/.og/at2.uheWG/igi', -- senha: password
  'Admin Master',
  'admin',
  true
);

-- Cliente demo
INSERT INTO account.users (email, password_hash, full_name, role, is_active)
VALUES (
  'cliente@demo.com',
  '$2y$10$92IXUNpkjO0rOQ5byMi.Ye4oKoEa3Ro9llC/.og/at2.uheWG/igi',
  'Cliente Demo',
  'customer',
  true
);

-- Dono de restaurante demo
INSERT INTO account.users (email, password_hash, full_name, role, is_active)
VALUES (
  'restaurante@demo.com',
  '$2y$10$92IXUNpkjO0rOQ5byMi.Ye4oKoEa3Ro9llC/.og/at2.uheWG/igi',
  'João Silva',
  'restaurant',
  true
);

-- Entregador demo
INSERT INTO account.users (email, password_hash, full_name, role, is_active)
VALUES (
  'entregador@demo.com',
  '$2y$10$92IXUNpkjO0rOQ5byMi.Ye4oKoEa3Ro9llC/.og/at2.uheWG/igi',
  'Carlos Motoboy',
  'courier',
  true
);

-- ============================================================================
-- RESTAURANTE DEMO
-- ============================================================================

INSERT INTO restaurant.restaurants (
  name, 
  trade_name, 
  cnpj, 
  city_ibge_code,
  address,
  settlement,
  platform_fee_bps,
  accepting_orders,
  is_open,
  risk_tier,
  deposit_required
)
VALUES (
  'Pizzaria Nonna',
  'Pizzaria Nonna',
  '12345678000199',
  '3550308', -- São Paulo
  '{"street": "Rua das Flores", "number": "123", "complement": "", "neighborhood": "Centro", "city": "São Paulo", "state": "SP", "zip": "01234567"}'::jsonb,
  'white_label',
  1500, -- 15% de comissão
  true,
  true,
  'standard',
  false
);

-- Horário de funcionamento padrão
INSERT INTO restaurant.operating_hours (restaurant_id, weekday, open_time, close_time, is_closed)
SELECT 
  (SELECT id FROM restaurant.restaurants WHERE cnpj = '12345678000199'),
  weekday,
  CASE WHEN weekday IN (0, 6) THEN '18:00:00'::time ELSE '09:00:00'::time END,
  '23:00:00'::time,
  CASE WHEN weekday IN (0, 6) THEN false ELSE false END
FROM generate_series(0, 6) AS weekday;

-- ============================================================================
-- CARDÁPIO DEMO
-- ============================================================================

DO $$
DECLARE
  v_restaurant_id uuid := (SELECT id FROM restaurant.restaurants WHERE cnpj = '12345678000199');
BEGIN
  -- Categoria: Pizzas
  INSERT INTO catalog.categories (restaurant_id, name, sort_order)
  VALUES (v_restaurant_id, 'Pizzas', 1);
  
  -- Categoria: Bebidas
  INSERT INTO catalog.categories (restaurant_id, name, sort_order)
  VALUES (v_restaurant_id, 'Bebidas', 2);
  
  -- Produtos - Pizzas
  INSERT INTO catalog.products (restaurant_id, category_id, name, description, price, is_available, sort_order)
  SELECT 
    v_restaurant_id,
    (SELECT id FROM catalog.categories WHERE name = 'Pizzas' AND restaurant_id = v_restaurant_id),
    nome,
    descricao,
    preco,
    true,
    row_number() OVER ()
  FROM (
    VALUES 
      ('Pizza Calabresa', 'Molho de tomate, mussarela, calabresa fatiada, cebola', 3990),
      ('Pizza Marguerita', 'Molho de tomate, mussarela, tomate fresco, manjericão', 4290),
      ('Pizza Portuguesa', 'Molho de tomate, mussarela, presunto, ovo, cebola, azeitona', 4590),
      ('Pizza Frango com Catupiry', 'Molho de tomate, frango desfiado, catupiry original', 4790)
  ) AS produtos(nome, descricao, preco);
  
  -- Produtos - Bebidas
  INSERT INTO catalog.products (restaurant_id, category_id, name, description, price, is_available, sort_order)
  SELECT 
    v_restaurant_id,
    (SELECT id FROM catalog.categories WHERE name = 'Bebidas' AND restaurant_id = v_restaurant_id),
    nome,
    descricao,
    preco,
    true,
    row_number() OVER ()
  FROM (
    VALUES 
      ('Coca-Cola 350ml', 'Lata gelada', 600),
      ('Guaraná Antarctica 350ml', 'Lata gelada', 600),
      ('Suco de Laranja Natural 500ml', 'Feito na hora', 1200),
      ('Água Mineral 500ml', 'Sem gás', 400)
  ) AS bebidas(nome, descricao, preco);
END $$;

-- ============================================================================
-- PEDIDO DEMO (Status: paid)
-- ============================================================================

DO $$
DECLARE
  v_restaurant_id uuid := (SELECT id FROM restaurant.restaurants WHERE cnpj = '12345678000199');
  v_customer_id uuid := (SELECT id FROM account.users WHERE email = 'cliente@demo.com');
  v_order_id uuid;
BEGIN
  -- Criar pedido
  INSERT INTO sales.orders (
    restaurant_id,
    customer_id,
    status,
    delivery_method,
    total,
    placed_at,
    paid_at
  )
  VALUES (
    v_restaurant_id,
    v_customer_id,
    'paid',
    'delivery',
    5190, -- Pizza + Coca
    now() - interval '30 minutes',
    now() - interval '29 minutes'
  )
  RETURNING id INTO v_order_id;
  
  -- Adicionar itens ao pedido
  INSERT INTO sales.order_items (order_id, product_id, quantity, unit_price, product_snapshot)
  SELECT 
    v_order_id,
    p.id,
    1,
    p.price,
    jsonb_build_object('name', p.name, 'description', p.description)
  FROM catalog.products p
  WHERE p.name IN ('Pizza Calabresa', 'Coca-Cola 350ml');
  
  -- Gravar eventos do pedido
  INSERT INTO sales.order_events (order_id, from_status, to_status, actor_role, note, created_at)
  VALUES 
    (v_order_id, NULL, 'cart', 'customer', 'Pedido iniciado', now() - interval '30 minutes'),
    (v_order_id, 'cart', 'pending_payment', 'customer', 'Aguardando pagamento', now() - interval '30 minutes'),
    (v_order_id, 'pending_payment', 'paid', 'system', 'Pagamento confirmado via PIX', now() - interval '29 minutes');
    
  RAISE NOTICE 'Pedido demo criado: %', v_order_id;
END $$;

-- ============================================================================
-- CONSENTIMENTOS LGPD DEMO
-- ============================================================================

INSERT INTO account.lgpd_consents (user_id, consent_type, granted, ip, user_agent)
SELECT 
  id,
  'data_processing',
  true,
  '127.0.0.1'::inet,
  'Mozilla/5.0 (Seed Script)'
FROM account.users;

-- ============================================================================
-- RESUMO
-- ============================================================================

SELECT 
  'USUÁRIOS CRIADOS:' as tipo,
  count(*) as quantidade
FROM account.users
UNION ALL
SELECT 
  'RESTAURANTES:',
  count(*)
FROM restaurant.restaurants
UNION ALL
SELECT 
  'PRODUTOS:',
  count(*)
FROM catalog.products
UNION ALL
SELECT 
  'PEDIDOS:',
  count(*)
FROM sales.orders;
