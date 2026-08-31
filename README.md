fuudelivery/
├── Backend/
│   ├── auth_api/             # Usuários, clientes, estabelecimentos, entregadores, zonas, assinaturas, refresh tokens
│   ├── orders_api/           # Pedidos, produtos, categorias, adicionais, cupons, fidelidade, reviews, pickup-code
│   ├── delivery_api/         # Solicitações de entrega, extrato; Dispatch Engine (matching, auto-calibração, split decay)
│   ├── payment_api/          # PIX/Cartão (AbacatePay), carteiras, chargebacks, split, webhook, Asaas wallet
│   ├── chat_api/             # Chat por pedido via WebSocket
│   └── storage/supabase.go   # Upload de imagens (Supabase Storage)
├── cmd/
│   ├── fuudelivery/          # Monolito principal (aglutina os 5 APIs) + pkg interno:
│   │                         #   health/ · queue/ · storage/ · upload/ · metrics/ · search/
│   ├── etl-orders/           # ETL one-shot Mongo → Postgres (orders → order_documents)
│   └── etl-payments/         # ETL one-shot Mongo → Postgres (payments/wallets/ledger)
├── pkg/
│   ├── gateway/              # Camada de abstração multi-gateway (interface Gateway + Router + CircuitBreaker)
│   │   ├── gateway.go        # Interface Gateway + tipos + enums (PaymentMethod, SplitRule, etc.)
│   │   ├── router.go         # Router com fallback chain e circuit breaker
│   │   ├── circuitbreaker.go # Circuit breaker (Closed → Open → HalfOpen)
│   │   ├── registry.go       # Registro e discovery de gateways
│   │   ├── pagarme/          # Adapter Pagar.me v4 (principal)
│   │   ├── asaas/            # Adapter Asaas (alternativo)
│   │   ├── abacatepay/       # Adapter AbacatePay (fallback PIX)
│   │   └── mercadopago/      # Adapter Mercado Pago (reserva)
│   ├── health/               # Health checks compartilháveis (Postgres, Redis)
│   └── queue/                # Fila Redis Streams + DLQ + fallback in-memory (compartilhável)
├── Frontend/
│   ├── AppComida/            # React Native/Expo — app do cliente (mapas MapLibre)
│   ├── AppEntrega/           # React Native/Expo — app do entregador (i18n)
│   ├── AppRestaurante/       # React Native/Expo — app do restaurante
│   ├── WebRestaurant/        # React 19 + Vite 6 + Tailwind 4 — kanban, cardápio, carteira, PWA
│   └── WebAdmin/             # React 19 + Vite 6 + Tailwind 4 — dashboard, pedidos, financeiro
├── legacy/PaymentPanel/      # Painel standalone arquivado (substituído pelo Financeiro do WebAdmin)
├── sql/                      # 13 migrações SQL versionadas + run_all.sh (ver seção Banco de Dados)
├── scripts/                  # Build APKs, deploy VPS, seeds, migrações, checks de CI (28 itens)
├── docs/                     # Arquitetura, banco de dados, deploy, segurança, FAQ, changelog
├── references/               # Docs internos (URLs, roadmap, gaps, testes, release notes)
├── .github/workflows/        # 7 workflows de CI/CD (ver seção CI/CD)
├── .pg-embed/                # Binários PostgreSQL 18.3 locais (dev/testes sem Docker)
├── Arquitetura/              # Diagramas (draw.io) e materiais visuais
├── brand/                    # Identidade visual e materiais comerciais
├── skills/fuudelivery-banco-unico/  # Regras obrigatórias p/ IA tocar no banco
├── Dockerfile                # Multi-stage (builder Go + runtime alpine, usuário não-root)
├── docker-compose.vps.yml    # Stack VPS: api + web-restaurant + web-admin + redis:7
├── render.yaml               # Blueprint Render (3 serviços)
├── Procfile                  # web: ./server
├── go.work                   # Go workspace com 10 módulos
└── MANIFEST.md · PRODUCTION.md · CONTRIBUTING.md · SECURITY.md · TRADEMARK.md
