<?php
/**
 * FUUDELIVERY · API ADVANCE ORDER
 * Fase 11.2 - Comanda do pedido (KDS actions)
 * 
 * Endpoint: POST /api/advance_order.php
 * Body: { order_id, to_status, note? }
 * 
 * Chama sales.advance_order() com FOR UPDATE e grava em order_events
 */

declare(strict_types=1);
header('Content-Type: application/json');

require_once __DIR__ . '/../shared/db.php';
require_once __DIR__ . '/../shared/auth.php';

if ($_SERVER['REQUEST_METHOD'] !== 'POST') {
    http_response_code(405);
    echo json_encode(['error' => 'Método não permitido']);
    exit;
}

$auth = Auth::requireRestaurant();
$restaurantId = $auth['restaurant_id'];
$userId = $auth['user_id'];

$input = json_decode(file_get_contents('php://input'), true);

if (empty($input['order_id']) || empty($input['to_status'])) {
    http_response_code(400);
    echo json_encode(['error' => 'order_id e to_status são obrigatórios']);
    exit;
}

$orderId = (int)$input['order_id'];
$toStatus = $input['to_status'];
$note = $input['note'] ?? null;

// Valida transição de status permitida
$validTransitions = [
    'paid' => ['preparing'],
    'preparing' => ['ready'],
    'ready' => ['delivering'],
    'delivering' => ['delivered']
];

$db = DB::getInstance();

try {
    $db->beginTransaction();
    
    // Busca pedido com FOR UPDATE (trava a linha)
    $stmt = $db->prepare("
        SELECT id, status, restaurant_id 
        FROM sales.orders 
        WHERE id = :order_id 
        FOR UPDATE
    ");
    $stmt->execute([':order_id' => $orderId]);
    $order = $stmt->fetch(PDO::FETCH_ASSOC);
    
    if (!$order) {
        throw new Exception('Pedido não encontrado');
    }
    
    // Valida que pertence ao restaurante
    if ($order['restaurant_id'] !== $restaurantId) {
        throw new Exception('Acesso negado a este pedido');
    }
    
    // Valida transição
    $currentStatus = $order['status'];
    if (!isset($validTransitions[$currentStatus]) || 
        !in_array($toStatus, $validTransitions[$currentStatus])) {
        throw new Exception("Transição inválida de {$currentStatus} para {$toStatus}");
    }
    
    // Chama função advance_order() do PostgreSQL
    $stmt = $db->prepare("
        SELECT sales.advance_order(
            :order_id, 
            :to_status, 
            :actor_id, 
            'restaurant', 
            :note
        ) as order_data
    ");
    
    $stmt->execute([
        ':order_id' => $orderId,
        ':to_status' => $toStatus,
        ':actor_id' => $userId,
        ':note' => $note
    ]);
    
    $result = $stmt->fetch(PDO::FETCH_ASSOC);
    
    $db->commit();
    
    // Retorna pedido atualizado
    echo json_encode([
        'success' => true,
        'order' => $result['order_data'],
        'message' => "Pedido movido para: {$toStatus}"
    ]);
    
} catch (Throwable $e) {
    $db->rollBack();
    error_log("Advance Order Error: " . $e->getMessage());
    http_response_code(400);
    echo json_encode([
        'success' => false,
        'error' => $e->getMessage()
    ]);
}
