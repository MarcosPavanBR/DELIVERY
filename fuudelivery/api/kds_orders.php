<?php
/**
 * FUUDELIVERY · API KDS ORDERS
 * Fase 11.1 - Kitchen Display System (tempo real via SSE)
 * 
 * Endpoint: GET /api/kds_orders.php?restaurant_id={uuid}
 * Retorna pedidos em status: paid, preparing, ready
 * Mantém conexão SSE aberta para notificações em tempo real
 */

declare(strict_types=1);
header('Content-Type: text/event-stream');
header('Cache-Control: no-cache');
header('Connection: keep-alive');
header('X-Accel-Buffering: no'); // Nginx: desabilita buffering

// Configuração de timeout para manter conexão viva
set_time_limit(0);
ini_set('default_socket_timeout', '-1');

require_once __DIR__ . '/../shared/db.php';
require_once __DIR__ . '/../shared/auth.php';

// Valida autenticação da loja
$auth = Auth::requireRestaurant();
$restaurantId = $auth['restaurant_id'];

// Valida parâmetro restaurant_id (loja só vê seus próprios pedidos)
if ($restaurantId !== ($_GET['restaurant_id'] ?? '')) {
    http_response_code(403);
    echo "data: " . json_encode(['error' => 'Acesso negado']) . "\n\n";
    flush();
    exit;
}

$db = DB::getInstance();

// Função para buscar pedidos do KDS
function getKdsOrders(PDO $db, string $restaurantId): array {
    $sql = "
        SELECT 
            o.id,
            o.public_code,
            o.status,
            o.total,
            o.payment_method,
            o.created_at,
            o.accepted_at,
            p.raw_response->>'payment_type' as card_type,
            p.raw_response->>'money_source' as money_source,
            ARRAY_AGG(oi.product_snapshot) FILTER (WHERE oi.product_snapshot IS NOT NULL) as items,
            ARRAY_AGG(oi.observation) FILTER (WHERE oi.observation IS NOT NULL) as observations
        FROM sales.orders o
        LEFT JOIN pay.payments p ON p.order_id = o.id AND p.status = 'approved'
        LEFT JOIN sales.order_items oi ON oi.order_id = o.id
        WHERE o.restaurant_id = :restaurant_id
          AND o.status IN ('paid', 'preparing', 'ready')
        GROUP BY o.id, p.raw_response
        ORDER BY o.created_at DESC
    ";
    
    $stmt = $db->prepare($sql);
    $stmt->execute([':restaurant_id' => $restaurantId]);
    return $stmt->fetchAll(PDO::FETCH_ASSOC);
}

// Envia estado inicial
$orders = getKdsOrders($db, $restaurantId);
echo "data: " . json_encode([
    'type' => 'initial',
    'orders' => $orders,
    'timestamp' => date('c')
]) . "\n\n";
flush();

// Escuta notificações do PostgreSQL via LISTEN
// O canal é específico por restaurante: kds_{restaurant_id}
$channel = 'kds_' . $restaurantId;

try {
    // Cria conexão dedicada para LISTEN (não pode ser a mesma das queries)
    $listenDb = new PDO(
        "pgsql:host={$GLOBALS['DB_HOST']};port={$GLOBALS['DB_PORT']};dbname={$GLOBALS['DB_NAME']}",
        $GLOBALS['DB_USER'],
        $GLOBALS['DB_PASS'],
        [PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION]
    );
    
    // Registra-se no canal de notificação
    $listenDb->exec("LISTEN \"{$channel}\"");
    
    // Loop infinito mantendo conexão SSE viva
    while (true) {
        // Aguarda notificação do PostgreSQL (timeout de 30s para heartbeat)
        $notification = $listenDb->quote($channel);
        $result = $listenDb->query("SELECT pg_notify_test({$notification}, '')");
        
        // Verifica se há notificações pendentes
        $notifications = [];
        while ($row = $listenDb->query("
            SELECT payload, 
                   EXTRACT(EPOCH FROM now()) as ts 
            FROM pg_listening_channels()
        ")->fetch(PDO::FETCH_ASSOC)) {
            $notifications[] = $row;
        }
        
        // Se houve notificação, busca pedidos atualizados e envia via SSE
        if (!empty($notifications)) {
            $orders = getKdsOrders($db, $restaurantId);
            echo "data: " . json_encode([
                'type' => 'update',
                'orders' => $orders,
                'timestamp' => date('c'),
                'sound' => 'new_order' // Trigger som no cliente
            ]) . "\n\n";
            flush();
        }
        
        // Heartbeat a cada 20 segundos para manter conexão viva
        echo ": heartbeat\n\n";
        flush();
        
        // Small delay para não sobrecarregar
        usleep(500000); // 500ms
    }
    
} catch (Throwable $e) {
    // Log do erro e reconexão automática pelo cliente
    error_log("SSE KDS Error: " . $e->getMessage());
    echo "data: " . json_encode([
        'type' => 'error',
        'message' => 'Erro na conexão em tempo real'
    ]) . "\n\n";
    flush();
}
