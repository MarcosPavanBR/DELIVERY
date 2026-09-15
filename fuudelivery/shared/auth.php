<?php
/**
 * FUUDELIVERY · AUTHENTICATION & RLS
 * Valida sessão e retorna contexto do usuário
 */

class Auth {
    /**
     * Valida autenticação de restaurante (tablet/KDS)
     * @return array{user_id: string, restaurant_id: string, role: 'restaurant'}
     */
    public static function requireRestaurant(): array {
        $session = self::getSession();

        if (!isset($session['user_id']) || !isset($session['restaurant_id'])) {
            http_response_code(401);
            echo json_encode(['error' => 'Não autorizado']);
            exit;
        }

        if ($session['role'] !== 'restaurant' && $session['role'] !== 'admin') {
            http_response_code(403);
            echo json_encode(['error' => 'Acesso negado: papel insuficiente']);
            exit;
        }

        // Seta variáveis de ambiente para RLS no DB
        putenv('APP_ROLE=restaurant');
        putenv("APP_RESTAURANT_ID={$session['restaurant_id']}");

        return [
            'user_id' => $session['user_id'],
            'restaurant_id' => $session['restaurant_id'],
            'role' => 'restaurant'
        ];
    }

    /**
     * Valida autenticação de admin (plataforma)
     * @return array{user_id: string, role: 'admin'}
     */
    public static function requireAdmin(): array {
        $session = self::getSession();

        if (!isset($session['user_id'])) {
            http_response_code(401);
            echo json_encode(['error' => 'Não autorizado']);
            exit;
        }

        if ($session['role'] !== 'admin') {
            http_response_code(403);
            echo json_encode(['error' => 'Acesso negado: apenas administradores']);
            exit;
        }

        putenv('APP_ROLE=admin');

        return [
            'user_id' => $session['user_id'],
            'role' => 'admin'
        ];
    }

    /**
     * Simula sessão via header (em produção usar cookie seguro)
     */
    private static function getSession(): array {
        $authHeader = $_SERVER['HTTP_AUTHORIZATION'] ?? '';
        
        if (preg_match('/Bearer\s+(.+)/', $authHeader, $matches)) {
            $token = $matches[1];
            // Em produção: validar JWT ou buscar sessão no banco/redis
            // Aqui: decode simples de base64 para demo
            $decoded = base64_decode($token, true);
            if ($decoded) {
                return json_decode($decoded, true) ?? [];
            }
        }

        // Fallback: lê de $_SESSION se disponível
        return $_SESSION['user'] ?? [];
    }
}
