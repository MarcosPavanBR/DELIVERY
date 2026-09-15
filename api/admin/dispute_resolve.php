<?php
/**
 * FUUDELIVERY · API DISPUTE RESOLVE
 * Fase 12.5 - Resolução de disputas com contrapartida no ledger
 * 
 * Endpoint: POST /api/admin/dispute_resolve.php
 * Body: { dispute_id, resolution, refund_amount?, resolution_note }
 * 
 * Decisão gera lançamento de contrapartida no ledger (append-only)
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

if (empty($input['dispute_id']) || empty($input['resolution'])) {
    http_response_code(400);
    echo json_encode(['error' => 'dispute_id e resolution são obrigatórios']);
    exit;
}

$disputeId = $input['dispute_id'];
$resolution = $input['resolution']; // full_refund, partial_refund, denied, reissued
$refundAmount = !empty($input['refund_amount']) ? (float)$input['refund_amount'] : 0;
$resolutionNote = $input['resolution_note'] ?? null;

// Valida resolução
$validResolutions = ['full_refund', 'partial_refund', 'denied', 'reissued'];
if (!in_array($resolution, $validResolutions)) {
    http_response_code(400);
    echo json_encode(['error' => 'Resolução inválida']);
    exit;
}

$db = DB::getInstance();

try {
    $db->beginTransaction();
    
    // Busca disputa com FOR UPDATE
    $stmt = $db->prepare("
        SELECT d.*, o.restaurant_id, o.total as order_total, p.id as payment_id
        FROM admin.disputes d
        JOIN sales.orders o ON o.id = d.order_id
        LEFT JOIN pay.payments p ON p.order_id = o.id AND p.status = 'approved'
        WHERE d.id = :dispute_id
        FOR UPDATE
    ");
    $stmt->execute([':dispute_id' => $disputeId]);
    $dispute = $stmt->fetch(PDO::FETCH_ASSOC);
    
    if (!$dispute) {
        throw new Exception('Disputa não encontrada');
    }
    
    if ($dispute['status'] !== 'open' && $dispute['status'] !== 'under_review') {
        throw new Exception('Disputa já foi resolvida');
    }
    
    // Valida valor do reembolso
    if (in_array($resolution, ['full_refund', 'partial_refund'])) {
        if ($refundAmount <= 0) {
            throw new Exception('Valor do reembolso deve ser maior que zero');
        }
        if ($refundAmount > $dispute['order_total']) {
            throw new Exception('Reembolso não pode exceder valor do pedido');
        }
    }
    
    // Atualiza status da disputa
    $stmt = $db->prepare("
        UPDATE admin.disputes
        SET 
            status = 'resolved',
            resolution = :resolution,
            refund_amount = :refund_amount,
            resolved_by = :resolved_by,
            resolution_note = :resolution_note,
            resolved_at = now()
        WHERE id = :dispute_id
    ");
    
    $stmt->execute([
        ':resolution' => $resolution,
        ':refund_amount' => $refundAmount > 0 ? $refundAmount : null,
        ':resolved_by' => $adminId,
        ':resolution_note' => $resolutionNote,
        ':dispute_id' => $disputeId
    ]);
    
    // Gera lançamentos no ledger (contrapartida append-only)
    if (in_array($resolution, ['full_refund', 'partial_refund']) && $refundAmount > 0) {
        $restaurantId = $dispute['restaurant_id'];
        
        // Lançamento 1: Débito na conta do restaurante (restaurant_payable)
        $stmt = $db->prepare("
            INSERT INTO finance.ledger_entries (
                account_type, account_ref, order_id, dispute_id,
                entry_type, amount, origin, created_by
            ) VALUES (
                'restaurant_payable', :account_ref, :order_id, :dispute_id,
                'refund_contraparty', :amount, 'dispute_resolution', :created_by
            )
        ");
        
        $stmt->execute([
            ':account_ref' => $restaurantId,
            ':order_id' => $dispute['order_id'],
            ':dispute_id' => $disputeId,
            ':amount' => -$refundAmount, // Negativo = débito
            ':created_by' => $adminId
        ]);
        
        // Lançamento 2: Crédito na conta do cliente (customer_receivable)
        // Se foi chargeback do Mercado Pago, creditamos platform_payable
        if (in_array($dispute['type'], ['chargeback_mp', 'chargeback_bitpay'])) {
            $stmt = $db->prepare("
                INSERT INTO finance.ledger_entries (
                    account_type, account_ref, order_id, dispute_id,
                    entry_type, amount, origin, created_by
                ) VALUES (
                    'platform_payable', :account_ref, :order_id, :dispute_id,
                    'chargeback', :amount, 'dispute_resolution', :created_by
                )
            ");
            
            $stmt->execute([
                ':account_ref' => $restaurantId, // Plataforma paga e cobra do restaurante depois
                ':order_id' => $dispute['order_id'],
                ':dispute_id' => $disputeId,
                ':amount' => $refundAmount, // Positivo = crédito
                ':created_by' => $adminId
            ]);
            
            // Marca pagamento como chargeback no Mercado Pago
            if ($dispute['payment_id']) {
                $stmt = $db->prepare("
                    UPDATE pay.payments
                    SET status = 'charged_back', updated_at = now()
                    WHERE id = :payment_id
                ");
                $stmt->execute([':payment_id' => $dispute['payment_id']]);
            }
        } else {
            // Reembolso normal: crédito para customer_receivable
            $stmt = $db->prepare("
                INSERT INTO finance.ledger_entries (
                    account_type, account_ref, order_id, dispute_id,
                    entry_type, amount, origin, created_by
                ) VALUES (
                    'customer_receivable', :account_ref, :order_id, :dispute_id,
                    'refund_contraparty', :amount, 'dispute_resolution', :created_by
                )
            ");
            
            $stmt->execute([
                ':account_ref' => $dispute['opened_by'], // Cliente que abriu disputa
                ':order_id' => $dispute['order_id'],
                ':dispute_id' => $disputeId,
                ':amount' => $refundAmount,
                ':created_by' => $adminId
            ]);
        }
        
        // Grava evento de auditoria no pedido
        $stmt = $db->prepare("
            INSERT INTO sales.order_events (
                order_id, from_status, to_status, actor_user_id, actor_role, note
            ) VALUES (
                :order_id, NULL, 'refunded', :actor_id, 'platform', :note
            )
        ");
        
        $stmt->execute([
            ':order_id' => $dispute['order_id'],
            ':actor_id' => $adminId,
            ':note' => "Reembolso de R$ {$refundAmount}: {$resolutionNote}"
        ]);
    }
    
    $db->commit();
    
    echo json_encode([
        'success' => true,
        'message' => 'Disputa resolvida com sucesso',
        'resolution' => $resolution,
        'refund_amount' => $refundAmount > 0 ? $refundAmount : null
    ]);
    
} catch (Throwable $e) {
    $db->rollBack();
    error_log("Dispute Resolve Error: " . $e->getMessage());
    http_response_code(400);
    echo json_encode([
        'success' => false,
        'error' => $e->getMessage()
    ]);
}
