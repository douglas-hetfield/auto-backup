#!/bin/bash

#==============================================================================
# Script de Instalação Automatizada
# Sistema de Backup MySQL → Google Drive
#==============================================================================

set -e  # Parar em caso de erro

echo "=========================================="
echo "INSTALADOR - Sistema de Backup MySQL"
echo "=========================================="
echo ""

# Cores para output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Função de log colorido
log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[AVISO]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERRO]${NC} $1"
}

# Verificar se está executando como root
if [ "$EUID" -ne 0 ]; then 
    log_error "Por favor, execute como root (sudo)"
    exit 1
fi

#log_info "Verificando sistema..."

# Detectar sistema operacional
#if [ -f /etc/os-release ]; then
#    . /etc/os-release
#    OS=$NAME
#    VER=$VERSION_ID
#else
#    log_error "Não foi possível detectar o sistema operacional"
#    exit 1
#fi

#log_info "Sistema detectado: $OS $VER"

# Atualizar sistema
log_info "Atualizando lista de pacotes..."
apt update -qq

# Instalar dependências
log_info "Instalando dependências..."
apt install -y zip unzip curl wget > /dev/null 2>&1

# Verificar instalações
log_info "Verificando instalações..."

if ! command -v mysql &> /dev/null; then
    log_error "MySQL client está instalado corretamente"
    exit 1
fi

if ! command -v zip &> /dev/null; then
    log_error "ZIP não foi instalado corretamente"
    exit 1
fi

log_info "Dependências instaladas com sucesso ✓"

# Instalar rclone
log_info "Instalando rclone..."
if ! command -v rclone &> /dev/null; then
    curl -s https://rclone.org/install.sh | bash
    if command -v rclone &> /dev/null; then
        log_info "rclone instalado com sucesso ✓"
    else
        log_error "Falha ao instalar rclone"
        exit 1
    fi
else
    log_info "rclone já está instalado ✓"
fi

# Criar estrutura de diretórios
log_info "Criando estrutura de diretórios..."
BASE_DIR="/var/www/backups"
mkdir -p "$BASE_DIR"/{base_dados,logs,config}

# Solicitar informações do usuário
echo ""
echo "=========================================="
echo "CONFIGURAÇÃO"
echo "=========================================="
echo ""

read -p "Usuário MySQL: " MYSQL_USER
read -sp "Senha MySQL: " MYSQL_PASSWORD
echo ""
read -p "Host MySQL [localhost]: " MYSQL_HOST
MYSQL_HOST=${MYSQL_HOST:-localhost}

read -p "Habilitar Google Drive? (s/n) [s]: " ENABLE_GDRIVE
ENABLE_GDRIVE=${ENABLE_GDRIVE:-s}

if [[ "$ENABLE_GDRIVE" == "s" || "$ENABLE_GDRIVE" == "S" ]]; then
    ENABLE_GDRIVE_BOOL="true"
    read -p "Nome do remote rclone [gdrive]: " GDRIVE_REMOTE
    GDRIVE_REMOTE=${GDRIVE_REMOTE:-gdrive}
    
    read -p "Pasta no Google Drive [Backups/MySQL]: " GDRIVE_FOLDER
    GDRIVE_FOLDER=${GDRIVE_FOLDER:-Backups/MySQL}
else
    ENABLE_GDRIVE_BOOL="false"
    GDRIVE_REMOTE="gdrive"
    GDRIVE_FOLDER="Backups/MySQL"
fi

read -p "Dias de retenção local [15]: " RETENTION_DAYS
RETENTION_DAYS=${RETENTION_DAYS:-15}

read -p "Dias de retenção de logs [30]: " LOG_RETENTION_DAYS
LOG_RETENTION_DAYS=${LOG_RETENTION_DAYS:-30}

# Criar arquivo .env
log_info "Criando arquivo de configuração..."
cat > "$BASE_DIR/.env" << EOF
# ============================================================================
# CONFIGURAÇÃO DE BACKUP MYSQL → GOOGLE DRIVE
# Gerado automaticamente em: $(date)
# ============================================================================

# CREDENCIAIS MYSQL
MYSQL_USER=$MYSQL_USER
MYSQL_PASSWORD=$MYSQL_PASSWORD
MYSQL_HOST=$MYSQL_HOST

# DIRETÓRIOS
BACKUP_BASE_DIR=$BASE_DIR/base_dados
LOG_BASE_DIR=$BASE_DIR/logs

# GOOGLE DRIVE (rclone)
ENABLE_GDRIVE=$ENABLE_GDRIVE_BOOL
GDRIVE_REMOTE=$GDRIVE_REMOTE
GDRIVE_FOLDER=$GDRIVE_FOLDER

# RETENÇÃO DE ARQUIVOS
RETENTION_DAYS=$RETENTION_DAYS
LOG_RETENTION_DAYS=$LOG_RETENTION_DAYS
EOF

# Definir permissões
chmod 600 "$BASE_DIR/.env"
log_info "Arquivo de configuração criado ✓"

# Testar conexão MySQL
log_info "Testando conexão com MySQL..."
if mysql -u "$MYSQL_USER" -p"$MYSQL_PASSWORD" -h "$MYSQL_HOST" -e "SELECT 1;" &> /dev/null; then
    log_info "Conexão MySQL bem-sucedida ✓"
else
    log_error "Falha ao conectar no MySQL. Verifique as credenciais."
    log_warning "Continuando instalação, mas ajuste o arquivo $BASE_DIR/.env"
fi

# Configurar permissões
log_info "Configurando permissões..."
chmod +x "$BASE_DIR/backup_mysql.sh" 2>/dev/null || true
chown -R www-data:www-data "$BASE_DIR" 2>/dev/null || true

echo ""
echo "=========================================="
echo "INSTALAÇÃO CONCLUÍDA"
echo "=========================================="
echo ""
log_info "Diretório base: $BASE_DIR"
log_info "Configuração: $BASE_DIR/.env"
log_info "Script: $BASE_DIR/backup_mysql.sh"
echo ""

if [[ "$ENABLE_GDRIVE_BOOL" == "true" ]]; then
    echo ""
    log_warning "PRÓXIMOS PASSOS:"
    echo ""
    echo "1. Configure o rclone para Google Drive:"
    echo "   rclone config"
    echo ""
    echo "2. Teste a conexão:"
    echo "   rclone ls $GDRIVE_REMOTE:"
    echo ""
    echo "3. Execute o backup manualmente:"
    echo "   cd $BASE_DIR && ./backup_mysql.sh"
    echo ""
    echo "4. Configure o cronjob (opcional):"
    echo "   sudo crontab -e"
    echo "   Adicione: 0 3 * * * $BASE_DIR/backup_mysql.sh"
    echo ""
else
    echo ""
    log_info "Para executar backup manualmente:"
    echo "   cd $BASE_DIR && ./backup_mysql.sh"
    echo ""
    log_info "Para configurar cronjob:"
    echo "   sudo crontab -e"
    echo "   Adicione: 0 3 * * * $BASE_DIR/backup_mysql.sh"
    echo ""
fi

log_info "Instalação finalizada com sucesso!"
echo ""