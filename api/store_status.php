<?php
/**
 * FUUDELIVERY · API STORE STATUS
 * Fase 11.3 - Pausar / reabrir loja (ato registrado)
 * 
 * Endpoints:
 * - GET /api/store_status.php?restaurant_id={uuid} → status atual + pausas ativas
 * - POST /api/store_status.php → { action: 'pause'|'resume', reason?, resume_at? }
 */

declare(strict_types=1);
header('Content-Type: application/json');

require_once __DIR__ . '/../shared/db.php';
require_once __DIR__ . '/../shared/auth.php';

$auth = Auth::requireRestaurant();
$restaurantId = $auth['restaurant_id'];
$userId = $auth['user_id'];

$db = DB::getInstance();
$method = $_SERVER['REQUEST_METHOD'];

if ($method === 'GET') {
    // Busca status atual da loja e pausas ativas
    $stmt = $db->prepare("
        SELECT 
            r.id,
            r.name,
            r.accepting_orders,
            r.is_open,
            sp.id as pause_id,
            sp.reason,
            sp.paused_at,
            sp.resume_at,
            u.full_name as paused_by_name
        FROM restaurant.restaurants r
        LEFT JOIN restaurant.store_pauses sp 
            ON sp.restaurant_id = r.id AND sp.active = true
        LEFT JOIN account.users u ON sp.paused_by = u.id
        WHERE r.id = :restaurant_id
    ");
    
    $stmt->execute([':restaurant_id' => $restaurantId]);
    $data = $stmt->fetch(PDO::FETCH_ASSOC);
    
    echo json_encode([
        'success' => true,
        'data' => $data ?: ['accepting_orders' => true, 'is_open' => false]
    ]);
    
} elseif ($method === 'POST') {
    $input = json_decode(file_get_contents('php://input'), true);
    $action = $input['action'] ?? null;
    
    if (!in_array($action, ['pause', 'resume'])) {
        http_response_code(400);
        echo json_encode(['error' => 'Ação deve ser "pause" ou "resume"']);
        exit;
    }
    
    try {
        $db->beginTransaction();
        
        if ($action === 'pause') {
            // Valida motivo obrigatório
            $reason = trim($input['reason'] ?? '');
            if (strlen($reason) < 3) {
                throw new Exception('Motivo da pausa é obrigatório (mínimo 3 caracteres)');
            }
            
            $resumeAt = !empty($input['resume_at']) ? $input['resume_at'] : null;
            
            // Marca restaurante como não aceitando pedidos
            $stmt = $db->prepare("
                UPDATE restaurant.restaurants 
                SET accepting_orders = false, updated_at = now()
                WHERE id = :restaurant_id
            ");
            $stmt->execute([':restaurant_id' => $restaurantId]);
            
            // Registra pausa com autor e motivo
            $stmt = $db->prepare("
                INSERT INTO restaurant.store_pauses 
                    (restaurant_id, paused_by, reason, resume_at, paused_at)
                VALUES 
                    (:restaurant_id, :paused_by, :reason, :resume_at, now())
            ");
            $stmt->execute([
                ':restaurant_id' => $restaurantId,
                ':paused_by' => $userId,
                ':reason' => $reason,
                ':resume_at' => $resumeAt
            ]);
            
            // Grava evento de auditoria
            $stmt = $db->prepare("
                INSERT INTO sales.order_events 
                    (order_id, from_status, to_status, actor_user_id, actor_role, note)
                VALUES 
                    (NULL, NULL, 'store_paused', :actor_id, 'restaurant', :note)
            ");
            $stmt->execute([
                ':actor_id' => $userId,
                ':note' => "Loja pausada: {$reason}"
            ]);
            
            $message = 'Loja pausada com sucesso';
            if ($resumeAt) {
                $message .= " às " . date('H:i', strtotime($resumeAt));
            }
            
        } else {
            // Resume: marca restaurante como aceitando pedidos
            $stmt = $db->prepare("
                UPDATE restaurant.restaurants 
                SET accepting_orders = true, updated_at = now()
                WHERE id = :restaurant_id
            ");
            $stmt->execute([':restaurant_id' => $restaurantId]);
            
            // Desativa pausa ativa
            $stmt = $db->prepare("
                UPDATE restaurant.store_pauses 
                SET active = false, resumed_at = now()
                WHERE restaurant_id = :restaurant_id AND active = true
            ");
            $stmt->execute([':restaurant_id' => $restaurantId]);
            
            // Grava evento de auditoria
            $stmt = $db->prepare("
                INSERT INTO sales.order_events 
                    (order_id, from_status, to_status, actor_user_id, actor_role, note)
                VALUES 
                    (NULL, NULL, 'store_resumed', :actor_id, 'restaurant', 'Loja reaberta')
            ");
            $stmt->execute([':actor_id' => $userId]);
            
            $message = 'Loja reaberta com sucesso';
        }
        
        $db->commit();
        
        echo json_encode([
            'success' => true,
            'message' => $message,
            'action' => $action
        ]);
        
    } catch (Throwable $e) {
        $db->rollBack();
        error_log("Store Status Error: " . $e->getMessage());
        http_response_code(400);
        echo json_encode([
            'success' => false,
            'error' => $e->getMessage()
        ]);
    }
    
} else {
    http_response_code(405);
    echo json_encode(['error' => 'Método não permitido']);
}
