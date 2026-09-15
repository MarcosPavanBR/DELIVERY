<?php
/**
 * FUUDELIVERY · TESTE UNITÁRIO: AUTH
 * 
 * Testa as funções de autenticação e RLS (Row Level Security)
 * 
 * @author AI Engineer
 * @version 1.0.0
 * @group auth
 */

require_once __DIR__ . '/../shared/auth.php';
require_once __DIR__ . '/../shared/db.php';

class AuthTest {
    
    private int $passed = 0;
    private int $failed = 0;
    
    /**
     * Testa geração e validação de token de restaurante
     */
    public function testRestaurantTokenGeneration(): void {
        echo "[TEST] testRestaurantTokenGeneration... ";
        
        // Simula dados de sessão válidos
        $sessionData = [
            'user_id' => '550e8400-e29b-41d4-a716-446655440000',
            'restaurant_id' => '660e8400-e29b-41d4-a716-446655440001',
            'role' => 'restaurant'
        ];
        
        // Codifica token (em produção seria JWT)
        $token = base64_encode(json_encode($sessionData));
        
        // Simula header Authorization
        $_SERVER['HTTP_AUTHORIZATION'] = "Bearer {$token}";
        
        try {
            $result = Auth::requireRestaurant();
            
            if ($result['user_id'] === $sessionData['user_id'] &&
                $result['restaurant_id'] === $sessionData['restaurant_id']) {
                echo "✓ PASS\n";
                $this->passed++;
            } else {
                echo "✗ FAIL: Dados não conferem\n";
                $this->failed++;
            }
        } catch (Exception $e) {
            echo "✗ FAIL: " . $e->getMessage() . "\n";
            $this->failed++;
        }
    }
    
    /**
     * Testa falha com token inválido
     */
    public function testInvalidToken(): void {
        echo "[TEST] testInvalidToken... ";
        
        $_SERVER['HTTP_AUTHORIZATION'] = "Bearer invalid_token_xyz";
        
        // Captura saída para evitar echo de erro
        ob_start();
        try {
            Auth::requireRestaurant();
            $output = ob_get_clean();
            echo "✗ FAIL: Deveria ter falhado\n";
            $this->failed++;
        } catch (Exception $e) {
            ob_end_clean();
            echo "✓ PASS (bloqueou token inválido)\n";
            $this->passed++;
        }
    }
    
    /**
     * Testa falha com papel insuficiente (customer tentando acessar endpoint de restaurante)
     */
    public function testInsufficientRole(): void {
        echo "[TEST] testInsufficientRole... ";
        
        $sessionData = [
            'user_id' => '550e8400-e29b-41d4-a716-446655440000',
            'role' => 'customer' // Papel errado
        ];
        
        $token = base64_encode(json_encode($sessionData));
        $_SERVER['HTTP_AUTHORIZATION'] = "Bearer {$token}";
        
        ob_start();
        try {
            Auth::requireRestaurant();
            $output = ob_get_clean();
            echo "✗ FAIL: Deveria ter bloqueado papel customer\n";
            $this->failed++;
        } catch (Exception $e) {
            ob_end_clean();
            echo "✓ PASS (bloqueou papel insuficiente)\n";
            $this->passed++;
        }
    }
    
    /**
     * Testa autenticação de admin
     */
    public function testAdminAuth(): void {
        echo "[TEST] testAdminAuth... ";
        
        $sessionData = [
            'user_id' => '770e8400-e29b-41d4-a716-446655440002',
            'role' => 'admin'
        ];
        
        $token = base64_encode(json_encode($sessionData));
        $_SERVER['HTTP_AUTHORIZATION'] = "Bearer {$token}";
        
        try {
            $result = Auth::requireAdmin();
            
            if ($result['role'] === 'admin') {
                echo "✓ PASS\n";
                $this->passed++;
            } else {
                echo "✗ FAIL: Role não é admin\n";
                $this->failed++;
            }
        } catch (Exception $e) {
            echo "✗ FAIL: " . $e->getMessage() . "\n";
            $this->failed++;
        }
    }
    
    /**
     * Testa customer tentando acessar admin
     */
    public function testCustomerAccessingAdmin(): void {
        echo "[TEST] testCustomerAccessingAdmin... ";
        
        $sessionData = [
            'user_id' => '550e8400-e29b-41d4-a716-446655440000',
            'role' => 'customer'
        ];
        
        $token = base64_encode(json_encode($sessionData));
        $_SERVER['HTTP_AUTHORIZATION'] = "Bearer {$token}";
        
        ob_start();
        try {
            Auth::requireAdmin();
            $output = ob_get_clean();
            echo "✗ FAIL: Deveria ter bloqueado\n";
            $this->failed++;
        } catch (Exception $e) {
            ob_end_clean();
            echo "✓ PASS (bloqueou acesso de customer a admin)\n";
            $this->passed++;
        }
    }
    
    /**
     * Executa todos os testes
     */
    public function runAll(): void {
        echo "\n=== FUUDELIVERY AUTH TEST SUITE ===\n\n";
        
        $this->testRestaurantTokenGeneration();
        $this->testInvalidToken();
        $this->testInsufficientRole();
        $this->testAdminAuth();
        $this->testCustomerAccessingAdmin();
        
        echo "\n=== RESULTADOS ===\n";
        echo "Passou: {$this->passed}\n";
        echo "Falhou: {$this->failed}\n";
        echo "Total:  " . ($this->passed + $this->failed) . "\n\n";
        
        if ($this->failed > 0) {
            exit(1);
        }
    }
}

// Executa testes
$test = new AuthTest();
$test->runAll();
