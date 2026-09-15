/**
 * FUUDELIVERY · KDS Module
 * Lógica do Kitchen Display System (Fase 11)
 */

const API_BASE = '/api';
let eventSource = null;
let ordersCache = new Map();

/**
 * Inicializa o KDS
 */
export function mountKDS(restaurantId) {
    // Atualiza horário
    updateTime();
    setInterval(updateTime, 1000);

    // Carrega nome do restaurante
    loadRestaurantName(restaurantId);

    // Conecta SSE
    connectSSE(restaurantId);

    // Configura botões
    setupButtons(restaurantId);

    // Loop de atualização dos timers
    setInterval(updateTimers, 1000);
}

/**
 * Conecta ao Server-Sent Events
 */
function connectSSE(restaurantId) {
    const url = `${API_BASE}/kds_orders.php?restaurant_id=${restaurantId}`;
    
    eventSource = new EventSource(url);

    eventSource.onopen = () => {
        updateConnectionStatus(true);
        console.log('[KDS] SSE conectado');
    };

    eventSource.onerror = (err) => {
        updateConnectionStatus(false);
        console.error('[KDS] SSE erro:', err);
        
        // Reconnect após 5 segundos
        setTimeout(() => {
            if (eventSource.readyState === EventSource.CLOSED) {
                connectSSE(restaurantId);
            }
        }, 5000);
    };

    eventSource.addEventListener('message', (e) => {
        const data = JSON.parse(e.data);
        
        if (data.type === 'initial') {
            // Estado inicial: renderiza todos os pedidos
            ordersCache.clear();
            data.orders.forEach(order => {
                ordersCache.set(order.id, order);
            });
            renderAllColumns();
        } else if (data.type === 'update') {
            // Atualização em tempo real
            if (data.order) {
                ordersCache.set(data.order.id, data.order);
                renderOrderCard(data.order);
                
                // Som de notificação para pedido novo
                if (data.order.status === 'paid') {
                    playNotificationSound();
                    showToast('Novo pedido recebido!', 'info');
                }
            }
        } else if (data.error) {
            showToast(`Erro: ${data.error}`, 'error');
        }
    });
}

/**
 * Renderiza todas as colunas
 */
function renderAllColumns() {
    const newOrders = Array.from(ordersCache.values()).filter(o => o.status === 'paid');
    const preparingOrders = Array.from(ordersCache.values()).filter(o => o.status === 'preparing');
    const readyOrders = Array.from(ordersCache.values()).filter(o => o.status === 'ready');

    renderColumn('new', newOrders);
    renderColumn('preparing', preparingOrders);
    renderColumn('ready', readyOrders);
}

/**
 * Renderiza uma coluna específica
 */
function renderColumn(status, orders) {
    const container = document.getElementById(`orders-${status}`);
    const countBadge = document.getElementById(`count-${status}`);
    
    if (!container) return;

    countBadge.textContent = orders.length;
    container.innerHTML = '';

    orders.forEach(order => {
        const card = createOrderCard(order);
        container.appendChild(card);
    });
}

/**
 * Renderiza/atualiza um cartão de pedido específico
 */
function renderOrderCard(order) {
    // Remove da posição antiga
    const oldCard = document.querySelector(`[data-order-id="${order.id}"]`);
    if (oldCard) oldCard.remove();

    // Adiciona na nova coluna
    const statusMap = {
        'paid': 'new',
        'preparing': 'preparing',
        'ready': 'ready'
    };

    const columnId = `orders-${statusMap[order.status]}`;
    const container = document.getElementById(columnId);
    
    if (container) {
        const card = createOrderCard(order);
        container.insertBefore(card, container.firstChild);
        
        // Atualiza contador
        const countBadge = document.getElementById(`count-${statusMap[order.status]}`);
        if (countBadge) {
            countBadge.textContent = container.children.length;
        }
    }
}

/**
 * Cria elemento HTML do cartão de pedido
 */
function createOrderCard(order) {
    const div = document.createElement('div');
    div.className = `order-card ${order.status}`;
    div.dataset.orderId = order.id;
    div.onclick = () => openOrderTicket(order);

    const paidAt = new Date(order.created_at);
    const elapsedMin = Math.floor((Date.now() - paidAt.getTime()) / 60000);
    
    let timerClass = '';
    if (elapsedMin >= 20) timerClass = 'timer-danger';
    else if (elapsedMin >= 10) timerClass = 'timer-warning';

    const items = Array.isArray(order.items) ? order.items : [];
    const itemsHtml = items.map(item => 
        `<div class="order-item">
            <strong>${item.quantity}x</strong> ${item.product_snapshot?.name || item.observation || 'Item'}
            ${item.observation ? `<br><small class="text-muted">${item.observation}</small>` : ''}
        </div>`
    ).join('');

    const actions = getActionsForStatus(order.status);

    div.innerHTML = `
        <div class="d-flex justify-content-between align-items-start">
            <div class="order-code">#${order.public_code || order.id}</div>
            <div class="order-timer ${timerClass}" data-order-id="${order.id}" data-paid-at="${paidAt.toISOString()}">
                ${formatElapsed(elapsedMin)}
            </div>
        </div>
        <div class="order-items">${itemsHtml}</div>
        <div class="d-flex justify-content-between align-items-center">
            <small class="text-muted">${formatPaymentMethod(order.payment_method)}</small>
            <strong>R$ ${(order.total / 100).toFixed(2)}</strong>
        </div>
        <div class="order-actions">
            ${actions}
        </div>
    `;

    return div;
}

/**
 * Retorna botões de ação baseados no status
 */
function getActionsForStatus(status) {
    switch (status) {
        case 'paid':
            return `<button class="btn btn-kds btn-primary" onclick="event.stopPropagation(); advanceOrder('${event.currentTarget.closest('[data-order-id]').dataset.orderId}', 'preparing')">
                        <i class="bi bi-fire me-1"></i> Iniciar Preparo
                    </button>`;
        case 'preparing':
            return `<button class="btn btn-kds btn-success" onclick="event.stopPropagation(); advanceOrder('${event.currentTarget.closest('[data-order-id]').dataset.orderId}', 'ready')">
                        <i class="bi bi-check-circle me-1"></i> Marcar Pronto
                    </button>`;
        case 'ready':
            return `<button class="btn btn-kds btn-info" onclick="event.stopPropagation(); callCourier('${event.currentTarget.closest('[data-order-id]').dataset.orderId}')">
                        <i class="bi bi-bicycle me-1"></i> Chamar Entregador
                    </button>`;
        default:
            return '';
    }
}

/**
 * Abre modal da comanda do pedido
 */
function openOrderTicket(order) {
    const items = Array.isArray(order.items) ? order.items : [];
    const itemsHtml = items.map(item => `
        <li class="list-group-item d-flex justify-content-between align-items-start">
            <div>
                <strong>${item.quantity}x</strong> ${item.product_snapshot?.name || 'Item'}
                ${item.observation ? `<br><small class="text-muted">${item.observation}</small>` : ''}
            </div>
        </li>
    `).join('');

    Swal.fire({
        title: `Pedido #${order.public_code || order.id}`,
        html: `
            <div class="text-start">
                <p><strong>Status:</strong> ${translateStatus(order.status)}</p>
                <p><strong>Pagamento:</strong> ${formatPaymentMethod(order.payment_method)}</p>
                <hr>
                <ul class="list-group list-group-flush">
                    ${itemsHtml}
                </ul>
                <hr>
                <div class="d-flex justify-content-between">
                    <strong>Total:</strong>
                    <strong>R$ ${(order.total / 100).toFixed(2)}</strong>
                </div>
            </div>
        `,
        showConfirmButton: true,
        confirmButtonText: 'Fechar',
        customClass: {
            popup: 'bg-dark text-white',
            title: 'text-white',
            confirmButton: 'btn btn-primary'
        },
        background: '#2d2d2d',
        color: '#f0f0f0'
    });
}

/**
 * Avança status do pedido
 */
window.advanceOrder = async function(orderId, toStatus) {
    try {
        const response = await fetch(`${API_BASE}/advance_order.php`, {
            method: 'POST',
            headers: {
                'Content-Type': 'application/json',
                'Authorization': `Bearer ${getAuthToken()}`
            },
            body: JSON.stringify({
                order_id: orderId,
                to_status: toStatus
            })
        });

        const result = await response.json();

        if (response.ok) {
            showToast(`Pedido movido para: ${translateStatus(toStatus)}`, 'success');
            
            // Imprime comanda (ESC/POS)
            if (toStatus === 'preparing') {
                printReceipt(orderId);
            }
        } else {
            showToast(`Erro: ${result.error}`, 'error');
        }
    } catch (err) {
        console.error(err);
        showToast('Erro de conexão', 'error');
    }
};

/**
 * Chama entregador (dispatch)
 */
window.callCourier = async function(orderId) {
    try {
        const response = await fetch(`${API_BASE}/dispatch_request.php`, {
            method: 'POST',
            headers: {
                'Content-Type': 'application/json',
                'Authorization': `Bearer ${getAuthToken()}`
            },
            body: JSON.stringify({ order_id: orderId })
        });

        const result = await response.json();

        if (response.ok) {
            showToast('Entregador sendo chamado...', 'info');
        } else {
            showToast(`Erro: ${result.error}`, 'error');
        }
    } catch (err) {
        console.error(err);
        showToast('Erro de conexão', 'error');
    }
};

/**
 * Pausar loja
 */
function setupButtons(restaurantId) {
    document.getElementById('btn-pause').onclick = () => {
        Swal.fire({
            title: 'Pausar Loja',
            input: 'textarea',
            inputLabel: 'Motivo da pausa (obrigatório)',
            inputPlaceholder: 'Ex: Falta de ingrediente, pico de demanda...',
            inputAttributes: { required: true },
            showCancelButton: true,
            confirmButtonText: 'Pausar',
            cancelButtonText: 'Cancelar',
            customClass: {
                popup: 'bg-dark text-white',
                title: 'text-white',
                input: 'form-control bg-dark text-white',
                confirmButton: 'btn btn-warning',
                cancelButton: 'btn btn-secondary'
            },
            background: '#2d2d2d',
            color: '#f0f0f0',
            preConfirm: (reason) => {
                if (!reason || reason.trim().length < 3) {
                    Swal.showValidationMessage('Motivo deve ter pelo menos 3 caracteres');
                    return false;
                }
                return reason;
            }
        }).then(async (result) => {
            if (result.isConfirmed) {
                await pauseStore(restaurantId, result.value);
            }
        });
    };

    document.getElementById('btn-fullscreen').onclick = () => {
        if (!document.fullscreenElement) {
            document.documentElement.requestFullscreen();
        } else {
            document.exitFullscreen();
        }
    };
}

/**
 * API: Pausar loja
 */
async function pauseStore(restaurantId, reason) {
    try {
        const response = await fetch(`${API_BASE}/store_status.php`, {
            method: 'POST',
            headers: {
                'Content-Type': 'application/json',
                'Authorization': `Bearer ${getAuthToken()}`
            },
            body: JSON.stringify({
                restaurant_id: restaurantId,
                action: 'pause',
                reason: reason
            })
        });

        const result = await response.json();

        if (response.ok) {
            showToast('Loja pausada com sucesso', 'warning');
            document.getElementById('restaurant-name').textContent += ' (PAUSADA)';
        } else {
            showToast(`Erro: ${result.error}`, 'error');
        }
    } catch (err) {
        console.error(err);
        showToast('Erro de conexão', 'error');
    }
}

/**
 * Atualiza timers dos pedidos
 */
function updateTimers() {
    document.querySelectorAll('.order-timer').forEach(timer => {
        const paidAt = new Date(timer.dataset.paidAt);
        const elapsedMin = Math.floor((Date.now() - paidAt.getTime()) / 60000);
        
        timer.textContent = formatElapsed(elapsedMin);
        timer.className = 'order-timer';
        
        if (elapsedMin >= 20) timer.classList.add('timer-danger');
        else if (elapsedMin >= 10) timer.classList.add('timer-warning');
    });
}

/**
 * Formata tempo decorrido
 */
function formatElapsed(minutes) {
    const h = Math.floor(minutes / 60);
    const m = minutes % 60;
    return h > 0 ? `${h}h${m}min` : `${m}min`;
}

/**
 * Atualiza conexão status
 */
function updateConnectionStatus(connected) {
    const statusEl = document.getElementById('connection-status');
    if (connected) {
        statusEl.className = 'connection-status status-connected';
        statusEl.innerHTML = '<i class="bi bi-wifi"></i> Conectado';
    } else {
        statusEl.className = 'connection-status status-disconnected';
        statusEl.innerHTML = '<i class="bi bi-wifi-off"></i> Desconectado';
    }
}

/**
 * Toca som de notificação
 */
function playNotificationSound() {
    const audio = new Audio('/sounds/notification.mp3');
    audio.play().catch(console.error);
}

/**
 * Mostra toast
 */
function showToast(message, type = 'info') {
    toastr[type](message);
}

/**
 * Imprime comanda (ESC/POS)
 */
function printReceipt(orderId) {
    // Em produção: enviar para impressora térmica via service worker ou backend
    console.log('[KDS] Imprimindo comanda:', orderId);
}

/**
 * Utilitários
 */
function updateTime() {
    const now = new Date();
    document.getElementById('current-time').textContent = 
        now.toLocaleString('pt-BR', { weekday: 'long', hour: '2-digit', minute: '2-digit' });
}

async function loadRestaurantName(restaurantId) {
    // Em produção: buscar nome da API
    document.getElementById('restaurant-name').textContent = 'Restaurante';
}

function translateStatus(status) {
    const map = {
        'paid': 'Pago',
        'preparing': 'Em Preparo',
        'ready': 'Pronto',
        'delivering': 'Em Entrega',
        'delivered': 'Entregue'
    };
    return map[status] || status;
}

function formatPaymentMethod(method) {
    const map = {
        'mp_card': 'Cartão (MP)',
        'pix_manual': 'PIX',
        'cash': 'Dinheiro',
        'bitpay': 'Bitcoin'
    };
    return map[method] || method;
}

function getAuthToken() {
    // Em produção: buscar de cookie seguro ou localStorage criptografado
    const auth = localStorage.getItem('fuudelivery_auth');
    return auth ? JSON.parse(auth).token : '';
}
