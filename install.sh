#!/bin/bash

#==============================================================================
# Script de Instalação Automatizada
# Sistema de Backup SQL Server (Docker/Alpine) -> Google Drive
#==============================================================================

set -e  # Parar em caso de erro

echo "=========================================="
echo "INSTALADOR - Backup SQL Server (Docker)"
echo "=========================================="
echo ""

# Cores para output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info()    { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[AVISO]${NC} $1"; }
log_error()   { echo -e "${RED}[ERRO]${NC} $1"; }

# Verificar se está executando como root
if [ "$(id -u)" -ne 0 ]; then
    log_error "Por favor, execute como root"
    exit 1
fi

#==============================================================================
# DEPENDÊNCIAS
#==============================================================================

log_info "Atualizando índice de pacotes (apk)..."
apk update -q

log_info "Instalando dependências..."
apk add --no-cache bash curl rclone > /dev/null 2>&1 || true

# rclone: tenta via apk, com fallback para o instalador oficial
if ! command -v rclone &> /dev/null; then
    log_warning "rclone não encontrado via apk, usando instalador oficial..."
    curl -s https://rclone.org/install.sh | bash
fi

if command -v rclone &> /dev/null; then
    log_info "rclone disponível ✓"
else
    log_error "Falha ao instalar o rclone"
    exit 1
fi

# Verificar Docker
if ! command -v docker &> /dev/null; then
    log_error "Docker não está instalado neste host"
    exit 1
fi

if ! docker info &> /dev/null; then
    log_error "Docker não está rodando. Inicie com: rc-service docker start"
    exit 1
fi
log_info "Docker disponível e rodando ✓"

#==============================================================================
# ESTRUTURA DE DIRETÓRIOS
#==============================================================================

BASE_DIR="/opt/sqlbackup"
LOG_BASE_DIR="/var/log/sqlbackup"

log_info "Criando estrutura de diretórios..."
mkdir -p "$BASE_DIR"
mkdir -p "$LOG_BASE_DIR"

#==============================================================================
# CONFIGURAÇÃO
#==============================================================================

echo ""
echo "=========================================="
echo "CONFIGURAÇÃO"
echo "=========================================="
echo ""

BACKUP_BASE_DIR_DEFAULT="/var/lib/docker/sqldata"
read -p "Diretório de dados dos containers [$BACKUP_BASE_DIR_DEFAULT]: " BACKUP_BASE_DIR
BACKUP_BASE_DIR=${BACKUP_BASE_DIR:-$BACKUP_BASE_DIR_DEFAULT}

SECRET_SHARED_DEFAULT="${BACKUP_BASE_DIR}/secrets/master_pass"
read -p "Arquivo de senha (shared) [$SECRET_SHARED_DEFAULT]: " SECRET_SHARED
SECRET_SHARED=${SECRET_SHARED:-$SECRET_SHARED_DEFAULT}

SECRET_DEDICATED_DEFAULT="${BACKUP_BASE_DIR}/secrets/master_pass_dedicated"
read -p "Arquivo de senha (dedicados) [$SECRET_DEDICATED_DEFAULT]: " SECRET_DEDICATED
SECRET_DEDICATED=${SECRET_DEDICATED:-$SECRET_DEDICATED_DEFAULT}

read -p "Habilitar Google Drive? (s/n) [s]: " ENABLE_GDRIVE
ENABLE_GDRIVE=${ENABLE_GDRIVE:-s}

if [[ "$ENABLE_GDRIVE" == "s" || "$ENABLE_GDRIVE" == "S" ]]; then
    ENABLE_GDRIVE_BOOL="true"
    read -p "Nome do remote rclone [gdrive]: " GDRIVE_REMOTE
    GDRIVE_REMOTE=${GDRIVE_REMOTE:-gdrive}
    read -p "Pasta no Google Drive [SQLBackups]: " GDRIVE_FOLDER
    GDRIVE_FOLDER=${GDRIVE_FOLDER:-SQLBackups}
else
    ENABLE_GDRIVE_BOOL="false"
    GDRIVE_REMOTE="gdrive"
    GDRIVE_FOLDER="SQLBackups"
fi

read -p "Dias de retenção de logs [30]: " LOG_RETENTION_DAYS
LOG_RETENTION_DAYS=${LOG_RETENTION_DAYS:-30}

#==============================================================================
# ARQUIVO .env
#==============================================================================

log_info "Criando arquivo de configuração..."
cat > "$BASE_DIR/.env" << EOF
# ============================================================================
# CONFIGURAÇÃO DE BACKUP SQL SERVER (Docker) -> GOOGLE DRIVE
# Gerado automaticamente em: $(date)
# ============================================================================

# Diretório base dos dados dos containers
BACKUP_BASE_DIR="$BACKUP_BASE_DIR"

# Arquivos de senha do SA
SECRET_SHARED="$SECRET_SHARED"
SECRET_DEDICATED="$SECRET_DEDICATED"

# Logs
LOG_BASE_DIR="$LOG_BASE_DIR"
LOG_RETENTION_DAYS=$LOG_RETENTION_DAYS

# Google Drive (rclone)
ENABLE_GDRIVE=$ENABLE_GDRIVE_BOOL
GDRIVE_REMOTE=$GDRIVE_REMOTE
GDRIVE_FOLDER=$GDRIVE_FOLDER
EOF

chmod 600 "$BASE_DIR/.env"
log_info "Arquivo de configuração criado ✓"

#==============================================================================
# SCRIPT DE BACKUP
#==============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ -f "$SCRIPT_DIR/backup_database.sh" ]; then
    log_info "Copiando script de backup..."
    cp "$SCRIPT_DIR/backup_database.sh" "$BASE_DIR/"
    chmod +x "$BASE_DIR/backup_database.sh"
    log_info "Script instalado em $BASE_DIR/backup_database.sh ✓"
else
    log_warning "backup_database.sh não encontrado em $SCRIPT_DIR"
    log_warning "Copie-o manualmente para $BASE_DIR/"
fi

#==============================================================================
# VALIDAÇÕES
#==============================================================================

log_info "Validando configuração..."

if [ -f "$SECRET_SHARED" ]; then
    log_info "Senha (shared) encontrada ✓"
else
    log_warning "Arquivo de senha (shared) não encontrado: $SECRET_SHARED"
fi

if [ -f "$SECRET_DEDICATED" ]; then
    log_info "Senha (dedicados) encontrada ✓"
else
    log_warning "Arquivo de senha (dedicados) não encontrado: $SECRET_DEDICATED"
fi

# Teste de conexão em um container, se houver
TEST_CONTAINER=$(docker ps --format '{{.Names}}' | grep '^sql-shared-01$' || true)
if [ -n "$TEST_CONTAINER" ] && [ -f "$SECRET_SHARED" ]; then
    log_info "Testando conexão em sql-shared-01..."
    PASS=$(tr -d '\r\n' < "$SECRET_SHARED")
    if docker exec -i sql-shared-01 /opt/mssql-tools18/bin/sqlcmd \
        -S localhost -U SA -P "$PASS" -C -Q "SELECT 1" &> /dev/null; then
        log_info "Conexão SQL Server bem-sucedida ✓"
    else
        log_warning "Não foi possível conectar no SQL Server. Verifique a senha."
    fi
fi

#==============================================================================
# CONCLUSÃO
#==============================================================================

echo ""
echo "=========================================="
echo "INSTALAÇÃO CONCLUÍDA"
echo "=========================================="
echo ""
log_info "Diretório base: $BASE_DIR"
log_info "Configuração:   $BASE_DIR/.env"
log_info "Script:         $BASE_DIR/backup_database.sh"
log_info "Logs:           $LOG_BASE_DIR"
echo ""

log_warning "PRÓXIMOS PASSOS:"
echo ""
echo "1. Configurar o rclone para o Google Drive (uma vez):"
echo "   rclone config"
echo "   (Alpine é headless: use a autenticação via 'rclone authorize'"
echo "    em outra máquina com navegador)"
echo ""
echo "2. Testar a conexão com o Drive:"
echo "   rclone ls $GDRIVE_REMOTE:"
echo ""
echo "3. Executar o backup manualmente:"
echo "   $BASE_DIR/backup_database.sh"
echo ""
echo "4. Agendar no cron (3h da manhã):"
echo "   crontab -e"
echo "   Adicione: 0 3 * * * $BASE_DIR/backup_database.sh"
echo ""
log_info "Instalação finalizada!"
echo ""