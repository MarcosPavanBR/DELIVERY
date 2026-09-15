<?php
/**
 * FUUDELIVERY · DB CONNECTION
 * Conexão PostgreSQL com PDO
 */

class DB {
    private static ?PDO $instance = null;

    public static function getInstance(): PDO {
        if (self::$instance === null) {
            $dsn = sprintf(
                'pgsql:host=%s;port=%d;dbname=%s;sslmode=require',
                getenv('DB_HOST') ?: 'localhost',
                getenv('DB_PORT') ?: 5432,
                getenv('DB_NAME') ?: 'fuudelivery'
            );

            self::$instance = new PDO(
                $dsn,
                getenv('DB_USER') ?: 'fuudelivery_user',
                getenv('DB_PASS') ?: '',
                [
                    PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION,
                    PDO::ATTR_DEFAULT_FETCH_MODE => PDO::FETCH_ASSOC,
                    PDO::ATTR_EMULATE_PREPARES => false,
                ]
            );

            // Seta contexto da sessão para RLS
            $role = getenv('APP_ROLE') ?: 'customer';
            self::$instance->exec("SET LOCAL app.role = '{$role}'");

            if ($restaurantId = getenv('APP_RESTAURANT_ID')) {
                self::$instance->exec("SET LOCAL app.restaurant_id = '{$restaurantId}'");
            }
        }

        return self::$instance;
    }

    private function __construct() {}
    private function __clone() {}
}
