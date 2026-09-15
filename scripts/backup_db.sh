#!/bin/bash
# FUUDELIVERY · SCRIPT DE BACKUP AUTOMÁTICO DO BANCO DE DADOS
# 
# Executa backup diário do PostgreSQL, compacta e remove backups antigos (>7 dias)
# Agendar no crontab: 0 3 * * * /var/www/fuudelivery/scripts/backup_db.sh
#
# @author AI Engineer
# @version 1.0.0

set -e

# Configurações
DB_CONTAINER="fuud_db_prod"
DB_USER="fuud_admin_prod"
DB_NAME="fuudelivery_prod"
BACKUP_DIR="/var/backups/fuudelivery"
DATE=$(date +%Y%m%d_%H%M%S)
BACKUP_FILE="$BACKUP_DIR/db_backup_$DATE.sql.gz"

# Criar diretório se não existir
mkdir -p "$BACKUP_DIR"

echo "=========================================="
echo "  FUUDELIVERY BACKUP DO BANCO DE DADOS"
echo "  Data: $(date)"
echo "=========================================="
echo ""

# Executar backup
echo "[1/3] Iniciando backup do banco de dados..."
docker exec "$DB_CONTAINER" pg_dump -U "$DB_USER" "$DB_NAME" | gzip > "$BACKUP_FILE"

if [ $? -eq 0 ]; then
    BACKUP_SIZE=$(du -h "$BACKUP_FILE" | cut -f1)
    echo "[2/3] Backup criado com sucesso: $BACKUP_FILE ($BACKUP_SIZE)"
else
    echo "[ERRO] Falha ao criar backup!"
    exit 1
fi

# Remover backups antigos (mais de 7 dias)
echo "[3/3] Limpando backups antigos (>7 dias)..."
OLD_BACKUPS=$(find "$BACKUP_DIR" -name "db_backup_*.sql.gz" -mtime +7 -type f | wc -l)

if [ "$OLD_BACKUPS" -gt 0 ]; then
    find "$BACKUP_DIR" -name "db_backup_*.sql.gz" -mtime +7 -type f -delete
    echo "       removidos $OLD_BACKUPS backup(s) antigo(s)"
else
    echo "       Nenhum backup antigo para remover"
fi

echo ""
echo "=========================================="
echo "  BACKUP CONCLUÍDO"
echo "  Arquivo: $BACKUP_FILE"
echo "  Tamanho: $BACKUP_SIZE"
echo "=========================================="

# Enviar notificação (opcional - integrar com Slack/Telegram)
# curl -X POST -H 'Content-type: application/json' \
#   --data "{\"text\":\"Backup FUUDELIVERY concluído: $BACKUP_FILE ($BACKUP_SIZE)\"}" \
#   https://hooks.slack.com/services/YOUR/WEBHOOK/URL

exit 0
