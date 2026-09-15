<?php
/**
 * FUUDELIVERY · API STORE APPROVE
 * Fase 12.2 - Aprovação de lojas (onboarding)
 * 
 * Endpoint: POST /api/admin/store_approve.php
 * Body: { onboarding_id, action: 'approve'|'reject', review_note?, fee_percent? }
 * 
 * Aprovar cria: restaurant + credentials + política padrão
 */

declare(strict_types=1);
header('Content-Type: application/json');

require_once __DIR__ . '/../../shared/db.php';
require_once __DIR__ . '/../../shared/auth.php';

if ($_SERVER['REQUEST_METHOD'] !== 'POST') {
    http_response_code(405);
    echo json_encode(['error' => 'Método não permitido']);
    exit;
}

$auth = Auth::requireAdmin();
$adminId = $auth['user_id'];

$input = json_decode(file_get_contents('php://input'), true);

if (empty($input['onboarding_id']) || empty($input['action'])) {
    http_response_code(400);
    echo json_encode(['error' => 'onboarding_id e action são obrigatórios']);
    exit;
}

$onboardingId = $input['onboarding_id'];
$action = $input['action'];
$reviewNote = $input['review_note'] ?? null;
$feePercent = $input['fee_percent'] ?? 15; // Taxa padrão 15%

$db = DB::getInstance();

try {
    $db->beginTransaction();
    
    // Busca onboarding com FOR UPDATE
    $stmt = $db->prepare("
        SELECT * FROM admin.store_onboarding
        WHERE id = :onboarding_id
        FOR UPDATE
    ");
    $stmt->execute([':onboarding_id' => $onboardingId]);
    $onboarding = $stmt->fetch(PDO::FETCH_ASSOC);
    
    if (!$onboarding) {
        throw new Exception('Onboarding não encontrado');
    }
    
    if ($onboarding['status'] !== 'submitted' && $onboarding['status'] !== 'docs_pending') {
        throw new Exception('Onboarding já foi processado');
    }
    
    if ($action === 'approve') {
        // Cria restaurante
        $stmt = $db->prepare("
            INSERT INTO restaurant.restaurants (
                name, trade_name, cnpj, city_ibge_code, address,
                settlement, platform_fee_bps, accepting_orders, is_open,
                risk_tier, deposit_required
            ) VALUES (
                :trade_name, :trade_name, :cnpj, :city_ibge_code,
                '{}'::jsonb, 'white_label', :fee_bps, true, false,
                :risk_tier, :deposit_required
            ) RETURNING id
        ");
        
        $stmt->execute([
            ':trade_name' => $onboarding['trade_name'],
            ':cnpj' => $onboarding['cnpj'],
            ':city_ibge_code' => $onboarding['city_ibge_code'],
            ':fee_bps' => (int)($feePercent * 100), // 15% = 1500 bps
            ':risk_tier' => $onboarding['risk_tier'],
            ':deposit_required' => $onboarding['deposit_required']
        ]);
        
        $restaurantId = $stmt->fetchColumn();
        
        // Atualiza onboarding com restaurant_id criado
        $stmt = $db->prepare("
            UPDATE admin.store_onboarding
            SET 
                restaurant_id = :restaurant_id,
                status = 'approved',
                reviewed_by = :reviewed_by,
                review_note = :review_note,
                proposed_fee_percent = :fee_percent,
                reviewed_at = now()
            WHERE id = :onboarding_id
        ");
        
        $stmt->execute([
            ':restaurant_id' => $restaurantId,
            ':reviewed_by' => $adminId,
            ':review_note' => $reviewNote,
            ':fee_percent' => $feePercent,
            ':onboarding_id' => $onboardingId
        ]);
        
        // Cria credenciais vazias (serão preenchidas pelo restaurante depois)
        $stmt = $db->prepare("
            INSERT INTO restaurant.restaurant_credentials (restaurant_id)
            VALUES (:restaurant_id)
        ");
        $stmt->execute([':restaurant_id' => $restaurantId]);
        
        // Cria horário padrão (Seg-Sex 9h-23h, Sáb-Dom 18h-23h)
        for ($weekday = 0; $weekday <= 6; $weekday++) {
            $isOpen = in_array($weekday, [0, 6]) ? false : true;
            $openTime = in_array($weekday, [0, 6]) ? '18:00:00' : '09:00:00';
            $closeTime = '23:00:00';
            
            $stmt = $db->prepare("
                INSERT INTO restaurant.operating_hours 
                    (restaurant_id, weekday, open_time, close_time, is_closed)
                VALUES 
                    (:restaurant_id, :weekday, :open_time, :close_time, :is_closed)
            ");
            $stmt->execute([
                ':restaurant_id' => $restaurantId,
                ':weekday' => $weekday,
                ':open_time' => $openTime,
                ':close_time' => $closeTime,
                ':is_closed' => !$isOpen
            ]);
        }
        
        $message = "Loja aprovada com sucesso. ID do restaurante: {$restaurantId}";
        
    } elseif ($action === 'reject') {
        if (empty($reviewNote)) {
            throw new Exception('Motivo da rejeição é obrigatório');
        }
        
        $stmt = $db->prepare("
            UPDATE admin.store_onboarding
            SET 
                status = 'rejected',
                reviewed_by = :reviewed_by,
                review_note = :review_note,
                reviewed_at = now()
            WHERE id = :onboarding_id
        ");
        
        $stmt->execute([
            ':reviewed_by' => $adminId,
            ':review_note' => $reviewNote,
            ':onboarding_id' => $onboardingId
        ]);
        
        $message = 'Loja rejeitada';
        
    } else {
        throw new Exception('Ação deve ser "approve" ou "reject"');
    }
    
    $db->commit();
    
    echo json_encode([
        'success' => true,
        'message' => $message,
        'restaurant_id' => $restaurantId ?? null,
        'action' => $action
    ]);
    
} catch (Throwable $e) {
    $db->rollBack();
    error_log("Store Approve Error: " . $e->getMessage());
    http_response_code(400);
    echo json_encode([
        'success' => false,
        'error' => $e->getMessage()
    ]);
}
