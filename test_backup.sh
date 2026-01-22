#!/bin/bash

#==============================================================================
# Script de Teste e Validação
# Sistema de Backup MySQL → Google Drive
#==============================================================================

# Cores
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"

# Contadores
TESTS_PASSED=0
TESTS_FAILED=0

# Funções de log
print_header() {
    echo ""
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}$1${NC}"
    echo -e "${BLUE}========================================${NC}"
    echo ""
}

test_pass() {
    echo -e "${GREEN}✓${NC} $1"
    ((TESTS_PASSED++))
}

test_fail() {
    echo -e "${RED}✗${NC} $1"
    ((TESTS_FAILED++))
}

test_info() {
    echo -e "${YELLOW}ℹ${NC} $1"
}

# Início dos testes
print_header "TESTE DE VALIDAÇÃO DO SISTEMA DE BACKUP"

# Teste 1: Verificar estrutura de diretórios
print_header "1. Estrutura de Diretórios"

if [ -d "$SCRIPT_DIR/base_dados" ]; then
    test_pass "Diretório base_dados existe"
else
    test_fail "Diretório base_dados não encontrado"
fi

if [ -d "$SCRIPT_DIR/logs" ]; then
    test_pass "Diretório logs existe"
else
    test_fail "Diretório logs não encontrado"
fi

# Teste 2: Verificar arquivos
print_header "2. Arquivos do Sistema"

if [ -f "$SCRIPT_DIR/backup_mysql.sh" ]; then
    test_pass "Script backup_mysql.sh encontrado"
    
    if [ -x "$SCRIPT_DIR/backup_mysql.sh" ]; then
        test_pass "Script é executável"
    else
        test_fail "Script não é executável (execute: chmod +x backup_mysql.sh)"
    fi
else
    test_fail "Script backup_mysql.sh não encontrado"
fi

if [ -f "$ENV_FILE" ]; then
    test_pass "Arquivo .env encontrado"
    
    # Verificar permissões
    PERMS=$(stat -c %a "$ENV_FILE")
    if [ "$PERMS" == "600" ] || [ "$PERMS" == "400" ]; then
        test_pass "Permissões do .env corretas ($PERMS)"
    else
        test_fail "Permissões do .env inseguras ($PERMS). Execute: chmod 600 .env"
    fi
else
    test_fail "Arquivo .env não encontrado"
    test_info "Copie .env.example para .env e configure"
    exit 1
fi

# Teste 3: Carregar e validar configurações
print_header "3. Configurações"

source "$ENV_FILE"

if [ -n "$MYSQL_USER" ]; then
    test_pass "MYSQL_USER configurado"
else
    test_fail "MYSQL_USER não configurado"
fi

if [ -n "$MYSQL_PASSWORD" ]; then
    test_pass "MYSQL_PASSWORD configurado"
else
    test_fail "MYSQL_PASSWORD não configurado"
fi

if [ -n "$MYSQL_HOST" ]; then
    test_pass "MYSQL_HOST configurado ($MYSQL_HOST)"
else
    test_fail "MYSQL_HOST não configurado"
fi

# Teste 4: Dependências do sistema
print_header "4. Dependências do Sistema"

if command -v mysql &> /dev/null; then
    MYSQL_VERSION=$(mysql --version | grep -oP '\d+\.\d+\.\d+' | head -1)
    test_pass "MySQL client instalado (versão $MYSQL_VERSION)"
else
    test_fail "MySQL client não instalado"
    test_info "Execute: sudo apt install mysql-client"
fi

if command -v zip &> /dev/null; then
    test_pass "ZIP instalado"
else
    test_fail "ZIP não instalado"
    test_info "Execute: sudo apt install zip"
fi

if command -v rclone &> /dev/null; then
    RCLONE_VERSION=$(rclone version | head -1 | awk '{print $2}')
    test_pass "rclone instalado (versão $RCLONE_VERSION)"
    
    # Verificar configuração do remote
    if [ "$ENABLE_GDRIVE" == "true" ]; then
        if rclone listremotes | grep -q "^${GDRIVE_REMOTE}:$"; then
            test_pass "Remote '$GDRIVE_REMOTE' configurado no rclone"
        else
            test_fail "Remote '$GDRIVE_REMOTE' não encontrado no rclone"
            test_info "Execute: rclone config"
        fi
    fi
else
    test_fail "rclone não instalado"
    test_info "Execute: curl https://rclone.org/install.sh | sudo bash"
fi

# Teste 5: Conectividade MySQL
print_header "5. Conectividade MySQL"

if command -v mysql &> /dev/null && [ -n "$MYSQL_USER" ] && [ -n "$MYSQL_PASSWORD" ]; then
    if mysql -u "$MYSQL_USER" -p"$MYSQL_PASSWORD" -h "$MYSQL_HOST" -e "SELECT 1;" &> /dev/null; then
        test_pass "Conexão MySQL bem-sucedida"
        
        # Contar bancos
        DB_COUNT=$(mysql -u "$MYSQL_USER" -p"$MYSQL_PASSWORD" -h "$MYSQL_HOST" -e "SHOW DATABASES;" | grep -Ev "Database|information_schema|performance_schema|mysql|sys" | wc -l)
        test_info "Bancos de dados encontrados: $DB_COUNT"
        
        if [ "$DB_COUNT" -gt 0 ]; then
            test_pass "Existem bancos para backup"
        else
            test_fail "Nenhum banco de dados encontrado para backup"
        fi
    else
        test_fail "Falha na conexão MySQL"
        test_info "Verifique as credenciais no arquivo .env"
    fi
else
    test_fail "Não foi possível testar conexão MySQL"
fi

# Teste 6: Google Drive (se habilitado)
if [ "$ENABLE_GDRIVE" == "true" ]; then
    print_header "6. Google Drive"
    
    if command -v rclone &> /dev/null; then
        if rclone ls "${GDRIVE_REMOTE}:" &> /dev/null; then
            test_pass "Conexão com Google Drive bem-sucedida"
            
            # Verificar se pasta existe
            if rclone lsd "${GDRIVE_REMOTE}:" | grep -q "Backups"; then
                test_info "Pasta 'Backups' encontrada no Google Drive"
            else
                test_info "Pasta 'Backups' não encontrada (será criada no primeiro backup)"
            fi
        else
            test_fail "Falha ao conectar no Google Drive"
            test_info "Execute: rclone config reconnect ${GDRIVE_REMOTE}:"
        fi
    fi
else
    test_info "Google Drive desabilitado na configuração"
fi

# Teste 7: Espaço em disco
print_header "7. Espaço em Disco"

DISK_USAGE=$(df -h "$SCRIPT_DIR" | awk 'NR==2 {print $5}' | sed 's/%//')
DISK_AVAIL=$(df -h "$SCRIPT_DIR" | awk 'NR==2 {print $4}')

test_info "Uso do disco: ${DISK_USAGE}%"
test_info "Espaço disponível: ${DISK_AVAIL}"

if [ "$DISK_USAGE" -lt 80 ]; then
    test_pass "Espaço em disco adequado"
else
    test_fail "Espaço em disco crítico (${DISK_USAGE}%)"
    test_info "Considere limpar backups antigos ou aumentar o disco"
fi

# Teste 8: Permissões de escrita
print_header "8. Permissões de Escrita"

if touch "$SCRIPT_DIR/base_dados/.test" 2>/dev/null; then
    rm "$SCRIPT_DIR/base_dados/.test"
    test_pass "Permissão de escrita em base_dados"
else
    test_fail "Sem permissão de escrita em base_dados"
fi

if touch "$SCRIPT_DIR/logs/.test" 2>/dev/null; then
    rm "$SCRIPT_DIR/logs/.test"
    test_pass "Permissão de escrita em logs"
else
    test_fail "Sem permissão de escrita em logs"
fi

# Teste 9: Cronjob (opcional)
print_header "9. Agendamento (Cronjob)"

if crontab -l 2>/dev/null | grep -q "backup_mysql.sh"; then
    test_pass "Cronjob configurado"
    test_info "Cronjob ativo:"
    crontab -l | grep backup_mysql.sh | sed 's/^/    /'
else
    test_info "Nenhum cronjob configurado"
    test_info "Para agendar backup diário às 3h:"
    echo "    sudo crontab -e"
    echo "    0 3 * * * $SCRIPT_DIR/backup_mysql.sh"
fi

# Resumo final
print_header "RESUMO DOS TESTES"

TOTAL_TESTS=$((TESTS_PASSED + TESTS_FAILED))

echo -e "${GREEN}Testes aprovados: $TESTS_PASSED${NC}"
echo -e "${RED}Testes falhados: $TESTS_FAILED${NC}"
echo -e "Total de testes: $TOTAL_TESTS"
echo ""

if [ $TESTS_FAILED -eq 0 ]; then
    echo -e "${GREEN}✓ Sistema pronto para uso!${NC}"
    echo ""
    echo "Execute o backup manualmente:"
    echo "  cd $SCRIPT_DIR && ./backup_mysql.sh"
    echo ""
    echo "Ou liste os bancos disponíveis:"
    echo "  cd $SCRIPT_DIR && ./backup_mysql.sh --list"
    exit 0
else
    echo -e "${RED}✗ Corrija os problemas antes de usar o sistema${NC}"
    echo ""
    echo "Revise as falhas acima e siga as instruções sugeridas"
    exit 1
fi