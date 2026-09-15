# FUUDELIVERY · PWA · 12 FASES · 59 TELAS

**Stack:** Svelte + Bootstrap + SweetAlert + toastr + PHP + PostgreSQL + Cloudflare

**Vertentes:** Cliente, Entregador, Loja (Tablet/KDS), Admin (Plataforma)

---

## ESTRUTURA DE PASTAS

```
fuudelivery/
├── apps/
│   ├── client-pwa/          # App do cliente (Fases 1-7)
│   ├── courier-app/         # App do entregador (Fase 8)
│   ├── restaurant-kds/      # Tablet da loja (Fases 3, 5, 11)
│   └── admin-panel/         # Painel da plataforma (Fases 9, 10, 12)
├── api/
│   ├── admin/               # Endpoints administrativos
│   │   ├── store_approve.php
│   │   ├── dispute_resolve.php
│   │   ├── dashboard.php
│   │   ├── commission.php
│   │   └── fraud_gallery.php
│   ├── kds_orders.php       # SSE para KDS (tempo real)
│   ├── advance_order.php    # Transição de status do pedido
│   ├── store_status.php     # Pausar/reabrir loja
│   ├── operating_hours.php  # Horário de funcionamento
│   ├── menu.php             # Cardápio (categorias e itens)
│   ├── product_update.php   # Edição de produto
│   └── restaurant_approval.php  # Aprovação de comprovante Pix
├── db/
│   └── master_schema.sql    # Schema completo PostgreSQL (Fases 1-12)
├── services/                # Serviços auxiliares
└── shared/                  # Bibliotecas compartilhadas
    ├── db.php               # Conexão PostgreSQL
    └── auth.php             # Autenticação e RLS
```

---

## FASES IMPLEMENTADAS

### Fase 11 — App do Restaurante em Tablet (KDS)

| Tela | Componente | Endpoint | Descrição |
|------|------------|----------|-----------|
| 11.1 KDS | `KdsBoard.svelte` | `GET /api/kds_orders.php` | Tela cheia com 3 colunas (NOVO, EM PREPARO, PRONTO). SSE via `LISTEN/NOTIFY` do PostgreSQL |
| 11.2 Comanda | `OrderTicket.svelte` | `POST /api/advance_order.php` | Botões grandes: Iniciar preparo, Marcar pronto, Chamar entregador. Chama `sales.advance_order()` |
| 11.3 Pausar loja | `StoreStatus.svelte` | `POST /api/store_status.php` | Pausa é ato registrado com motivo e autor. Bloqueia checkout no servidor |
| 11.4 Horário | `HoursEditor.svelte` | `GET/POST /api/operating_hours.php` | Grade semanal + datas especiais. "Aberto agora" calculado no servidor |
| 11.5 Cardápio | `MenuManager.svelte` | `GET/POST /api/menu.php` | Categorias accordion, itens com foto e toggle de esgotado |
| 11.6 Editar item | `ProductEditor.svelte` | `POST /api/product_update.php` | Troca de preço pede confirmação. Foto sobe para Cloudflare R2 |
| 11.7 Validação Pix | `ProofQueue.svelte` | `POST /api/restaurant_approval.php` | Badge sonoro prioritário. `FOR UPDATE` evita dupla aprovação |

### Fase 12 — Painel da Plataforma (Admin)

| Tela | Componente | Endpoint | Descrição |
|------|------------|----------|-----------|
| 12.1 Dashboard | `AdminDashboard.svelte` | `GET /api/admin/dashboard.php` | GMV, taxa, frete, espécie não baixada. Lê `mv_daily_gmv` |
| 12.2 Onboarding | `StoreOnboarding.svelte` | `POST /api/admin/store_approve.php` | Aprovar cria restaurante + credenciais + horário padrão |
| 12.3 Comissão | `CommissionEditor.svelte` | `POST /api/admin/commission.php` | Override por loja/praça. Vale só para pedidos futuros |
| 12.4 Disputas | `DisputesQueue.svelte` | `GET /api/admin/disputes.php` | Fila única com SLA. Cliente, entregador, loja, chargeback |
| 12.5 Detalhe disputa | `DisputeDetail.svelte` | `POST /api/admin/dispute_resolve.php` | Decisão gera contrapartida no ledger (append-only) |
| 12.6 Antifraude | `FraudGallery.svelte` | `GET/POST /api/admin/fraud_gallery.php` | sha256+phash repetido. Expurgo automático após 180 dias (LGPD) |
| 12.7 Relatórios | `Reports.svelte` | `GET /api/admin/reports.php` | Exporta CSV de `mv_daily_gmv` e `mv_store_netting` |

---

## BANCO DE DADOS (PostgreSQL 16)

### Schemas

- `account` — Usuários, OTP, consentimentos LGPD
- `restaurant` — Lojas, credenciais, horários, pausas
- `catalog` — Categorias, produtos, extras
- `sales` — Pedidos, itens, order_events (linha do tempo)
- `pay` — Pagamentos, comprovantes, webhooks
- `finance` — Ledger entries (append-only), store_freight
- `admin` — Store_onboarding, disputes
- `risk` — Fraud_events (expiração 180d)
- `delivery` — Couriers, dispatches

### Funções Críticas

```sql
sales.advance_order(order_id, to_status, actor_id, actor_role, note)
  → Transiciona pedido, grava order_events, notifica via pg_notify
```

### Views Materializadas

```sql
admin.mv_daily_gmv        -- GMV diário por loja
admin.mv_store_netting    -- Netting semanal (G MV, taxa, frete, a coletar)
```

### Row Level Security (RLS)

- `auth.is_admin()` — Admin vê tudo
- `auth.is_restaurant(id)` — Loja vê apenas seus dados
- `auth.is_owner(user_id)` — Cliente vê seus pedidos

---

## ENDPOINTS PRINCIPAIS

### KDS (Tablet)

| Método | Endpoint | Descrição |
|--------|----------|-----------|
| GET | `/api/kds_orders.php?restaurant_id={uuid}` | SSE stream com pedidos em tempo real |
| POST | `/api/advance_order.php` | `{order_id, to_status, note}` |
| GET | `/api/store_status.php?restaurant_id={uuid}` | Status atual da loja |
| POST | `/api/store_status.php` | `{action: 'pause'|'resume', reason?, resume_at?}` |
| GET | `/api/operating_hours.php?restaurant_id={uuid}` | Horário semanal + especial |
| POST | `/api/operating_hours.php` | Atualiza horários |
| GET | `/api/menu.php?restaurant_id={uuid}` | Cardápio completo |
| POST | `/api/product_update.php` | Atualiza produto (preço, foto, disponibilidade) |
| POST | `/api/restaurant_approval.php` | Aprova/rejeita comprovante Pix |

### Admin (Plataforma)

| Método | Endpoint | Descrição |
|--------|----------|-----------|
| GET | `/api/admin/dashboard.php` | Métricas da plataforma (GMV, taxa, etc.) |
| POST | `/api/admin/store_approve.php` | `{onboarding_id, action, review_note, fee_percent}` |
| POST | `/api/admin/commission.php` | Define comissão por loja/praça |
| GET | `/api/admin/disputes.php` | Lista disputas abertas |
| POST | `/api/admin/dispute_resolve.php` | `{dispute_id, resolution, refund_amount, note}` |
| GET | `/api/admin/fraud_gallery.php` | Eventos de fraude |
| POST | `/api/admin/fraud_gallery.php` | Ações: bloquear usuário, sinalizar loja |
| GET | `/api/admin/reports.php?type=gmv|netting&format=csv` | Exporta relatórios |

---

## REGRAS DE NEGÓCIO CRÍTICAS

### 1. Cozinha só vê o que está pago
- KDS filtra `status IN ('paid', 'preparing', 'ready')`
- Pedido novo chega via SSE alimentado por `pg_notify('kds_{restaurant_id}')`

### 2. Pausar loja é ato registrado
- Motivo obrigatório (mínimo 3 caracteres)
- Autor e hora gravados em `store_pauses`
- Checkout bloqueado no servidor (`accepting_orders = false`)

### 3. Reembolso é contrapartida (nunca edição)
- Ledger append-only: `finance.ledger_entries`
- Saldo é `SUM(amount)` por conta
- Correção é lançamento de contrapartida

### 4. Transição de pedido passa por `advance_order()`
- Valida transição permitida
- Grava em `order_events` (auditoria)
- Notifica KDS e despacho via `pg_notify`

### 5. LGPD: expurgo automático após 180 dias
- `risk.fraud_events.expires_at`
- Job diário (`pg_cron`) remove expirados

---

## PRÓXIMOS PASSOS

1. **Criar componentes Svelte** para cada tela listada acima
2. **Implementar bridge SSE** em PHP para conectar `LISTEN/NOTIFY` do Postgres
3. **Configurar Cloudflare R2** para upload de fotos e comprovantes
4. **Integrar Mercado Pago** (webhook + split de pagamento)
5. **Criar scripts de seed** para dados de teste

---

**Documento gerado automaticamente a partir do esboço FUUDelivery v2**
Última atualização: Setembro 2025
