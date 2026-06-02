#!/bin/bash

#==============================================================================
# Script de Teste e Validação
# Sistema de Backup SQL Server (Docker/Alpine) -> Google Drive
#==============================================================================

# Cores
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"

# Caminho do sqlcmd dentro dos containers
SQLCMD="/opt/mssql-tools18/bin/sqlcmd"

# Contadores
TESTS_PASSED=0
TESTS_FAILED=0

print_header() {
    echo ""
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}$1${NC}"
    echo -e "${BLUE}========================================${NC}"
    echo ""
}

test_pass() { echo -e "${GREEN}✓${NC} $1"; ((TESTS_PASSED++)); }
test_fail() { echo -e "${RED}✗${NC} $1"; ((TESTS_FAILED++)); }
test_info() { echo -e "${YELLOW}ℹ${NC} $1"; }

#==============================================================================
print_header "TESTE DE VALIDAÇÃO DO SISTEMA DE BACKUP"

#==============================================================================
# 1. Arquivos do sistema
#==============================================================================
print_header "1. Arquivos do Sistema"

if [ -f "$SCRIPT_DIR/backup_database.sh" ]; then
    test_pass "Script backup_database.sh encontrado"
    if [ -x "$SCRIPT_DIR/backup_database.sh" ]; then
        test_pass "Script é executável"
    else
        test_fail "Script não é executável (execute: chmod +x backup_database.sh)"
    fi
else
    test_fail "Script backup_database.sh não encontrado"
fi

if [ -f "$ENV_FILE" ]; then
    test_pass "Arquivo .env encontrado"
    PERMS=$(stat -c %a "$ENV_FILE" 2>/dev/null)
    if [ "$PERMS" == "600" ] || [ "$PERMS" == "400" ]; then
        test_pass "Permissões do .env corretas ($PERMS)"
    else
        test_fail "Permissões do .env inseguras ($PERMS). Execute: chmod 600 .env"
    fi
else
    test_fail "Arquivo .env não encontrado"
    test_info "Copie o .env de exemplo e configure"
    exit 1
fi

#==============================================================================
# 2. Configurações
#==============================================================================
print_header "2. Configurações"

source "$ENV_FILE"

BACKUP_BASE_DIR="${BACKUP_BASE_DIR:-/var/lib/docker/sqldata}"
LOG_BASE_DIR="${LOG_BASE_DIR:-/var/log/sqlbackup}"

if [ -n "$BACKUP_BASE_DIR" ]; then
    test_pass "BACKUP_BASE_DIR configurado ($BACKUP_BASE_DIR)"
else
    test_fail "BACKUP_BASE_DIR não configurado"
fi

if [ "${#SHARED_CONTAINERS[@]}" -gt 0 ] || [ "${#DEDICATED_CONTAINERS[@]}" -gt 0 ]; then
    test_pass "Listas de containers carregadas (shared: ${#SHARED_CONTAINERS[@]}, dedicados: ${#DEDICATED_CONTAINERS[@]})"
else
    test_fail "Nenhum container definido no .env (SHARED_CONTAINERS / DEDICATED_CONTAINERS)"
fi

if [ -f "$SECRET_SHARED" ]; then
    test_pass "Senha (shared) encontrada"
else
    test_fail "Senha (shared) não encontrada: $SECRET_SHARED"
fi

if [ -f "$SECRET_DEDICATED" ]; then
    test_pass "Senha (dedicados) encontrada"
else
    test_fail "Senha (dedicados) não encontrada: $SECRET_DEDICATED"
fi

#==============================================================================
# 3. Dependências do sistema
#==============================================================================
print_header "3. Dependências do Sistema"

if command -v docker &> /dev/null; then
    test_pass "Docker instalado"
    if docker info &> /dev/null; then
        test_pass "Docker está rodando"
    else
        test_fail "Docker não está rodando (rc-service docker start)"
    fi
else
    test_fail "Docker não instalado"
fi

if command -v rclone &> /dev/null; then
    RCLONE_VERSION=$(rclone version 2>/dev/null | head -1 | awk '{print $2}')
    test_pass "rclone instalado (versão $RCLONE_VERSION)"
    if [ "$ENABLE_GDRIVE" == "true" ]; then
        if rclone listremotes 2>/dev/null | grep -q "^${GDRIVE_REMOTE}:$"; then
            test_pass "Remote '$GDRIVE_REMOTE' configurado no rclone"
        else
            test_fail "Remote '$GDRIVE_REMOTE' não encontrado no rclone"
            test_info "Execute: rclone config"
        fi
    fi
else
    test_fail "rclone não instalado"
    test_info "Execute: apk add rclone"
fi

#==============================================================================
# 4. Containers SQL Server
#==============================================================================
print_header "4. Containers SQL Server"

ALL_CONTAINERS=("${SHARED_CONTAINERS[@]}" "${DEDICATED_CONTAINERS[@]}")
RUNNING_COUNT=0
STOPPED_COUNT=0

for container in "${ALL_CONTAINERS[@]}"; do
    if docker ps --format '{{.Names}}' | grep -q "^${container}$"; then
        ((RUNNING_COUNT++))
    else
        test_fail "Container parado/ausente: $container"
        ((STOPPED_COUNT++))
    fi
done

test_info "Containers rodando: $RUNNING_COUNT / ${#ALL_CONTAINERS[@]}"
if [ "$STOPPED_COUNT" -eq 0 ]; then
    test_pass "Todos os containers estão ativos"
fi

#==============================================================================
# 5. Conectividade SQL Server + contagem de bancos
#==============================================================================
print_header "5. Conectividade SQL Server"

if [ -f "$SECRET_SHARED" ]; then PASS_SHARED=$(tr -d '\r\n' < "$SECRET_SHARED"); fi
if [ -f "$SECRET_DEDICATED" ]; then PASS_DEDICATED=$(tr -d '\r\n' < "$SECRET_DEDICATED"); fi

TOTAL_DBS=0

check_container_dbs() {
    local container=$1
    local password=$2

    docker ps --format '{{.Names}}' | grep -q "^${container}$" || return

    local count
    count=$(docker exec -i "$container" "$SQLCMD" \
        -S localhost -U SA -P "$password" -C -h -1 -W \
        -Q "SET NOCOUNT ON; SELECT COUNT(*) FROM sys.databases WHERE database_id > 4 AND state = 0;" \
        2>/dev/null | tr -d '[:space:]')

    if [[ "$count" =~ ^[0-9]+$ ]]; then
        test_pass "$container: conexão OK ($count banco(s))"
        TOTAL_DBS=$((TOTAL_DBS + count))
    else
        test_fail "$container: falha na conexão (verifique a senha)"
    fi
}

for container in "${SHARED_CONTAINERS[@]}"; do
    check_container_dbs "$container" "$PASS_SHARED"
done
for container in "${DEDICATED_CONTAINERS[@]}"; do
    check_container_dbs "$container" "$PASS_DEDICATED"
done

test_info "Total de bancos de usuário a fazer backup: $TOTAL_DBS"
if [ "$TOTAL_DBS" -gt 0 ]; then
    test_pass "Existem bancos para backup"
else
    test_fail "Nenhum banco de usuário encontrado"
fi

#==============================================================================
# 6. Google Drive
#==============================================================================
if [ "$ENABLE_GDRIVE" == "true" ]; then
    print_header "6. Google Drive"
    if command -v rclone &> /dev/null; then
        if rclone ls "${GDRIVE_REMOTE}:" &> /dev/null; then
            test_pass "Conexão com Google Drive bem-sucedida"
            if rclone lsd "${GDRIVE_REMOTE}:" 2>/dev/null | grep -q "$GDRIVE_FOLDER"; then
                test_info "Pasta '$GDRIVE_FOLDER' encontrada no Drive"
            else
                test_info "Pasta '$GDRIVE_FOLDER' não existe (será criada no 1º backup)"
            fi
        else
            test_fail "Falha ao conectar no Google Drive"
            test_info "Execute: rclone config reconnect ${GDRIVE_REMOTE}:"
        fi
    fi
else
    test_info "Google Drive desabilitado na configuração"
fi

#==============================================================================
# 7. Espaço em disco (disco de dados)
#==============================================================================
print_header "7. Espaço em Disco"

DISK_USAGE=$(df -h "$BACKUP_BASE_DIR" 2>/dev/null | awk 'NR==2 {print $5}' | sed 's/%//')
DISK_AVAIL=$(df -h "$BACKUP_BASE_DIR" 2>/dev/null | awk 'NR==2 {print $4}')

test_info "Disco de dados ($BACKUP_BASE_DIR)"
test_info "Uso: ${DISK_USAGE}% | Disponível: ${DISK_AVAIL}"

if [ -n "$DISK_USAGE" ] && [ "$DISK_USAGE" -lt 80 ]; then
    test_pass "Espaço em disco adequado"
else
    test_fail "Espaço em disco crítico (${DISK_USAGE}%)"
    test_info "Considere liberar espaço ou aumentar o disco"
fi

#==============================================================================
# 8. Permissões de escrita (pastas de backup)
#==============================================================================
print_header "8. Permissões de Escrita"

WRITE_OK=0
WRITE_FAIL=0
for container in "${ALL_CONTAINERS[@]}"; do
    folder="${container#sql-}"
    backup_dir="${BACKUP_BASE_DIR}/${folder}/backup"
    [ -d "$backup_dir" ] || continue
    if touch "${backup_dir}/.write_test" 2>/dev/null; then
        rm -f "${backup_dir}/.write_test"
        ((WRITE_OK++))
    else
        test_fail "Sem escrita em: $backup_dir"
        ((WRITE_FAIL++))
    fi
done

if [ "$WRITE_FAIL" -eq 0 ] && [ "$WRITE_OK" -gt 0 ]; then
    test_pass "Permissão de escrita OK em $WRITE_OK pasta(s) de backup"
fi

# Log dir
if touch "${LOG_BASE_DIR}/.write_test" 2>/dev/null; then
    rm -f "${LOG_BASE_DIR}/.write_test"
    test_pass "Permissão de escrita em $LOG_BASE_DIR"
else
    test_fail "Sem permissão de escrita em $LOG_BASE_DIR"
fi

#==============================================================================
# 9. Agendamento (Cronjob)
#==============================================================================
print_header "9. Agendamento (Cronjob)"

if crontab -l 2>/dev/null | grep -q "backup_database.sh"; then
    test_pass "Cronjob configurado"
    test_info "Cronjob ativo:"
    crontab -l 2>/dev/null | grep "backup_database.sh" | sed 's/^/    /'
else
    test_info "Nenhum cronjob configurado"
    test_info "Para agendar backup diário às 3h:"
    echo "    crontab -e"
    echo "    0 3 * * * $SCRIPT_DIR/backup_database.sh"
fi

#==============================================================================
# RESUMO
#==============================================================================
print_header "RESUMO DOS TESTES"

TOTAL_TESTS=$((TESTS_PASSED + TESTS_FAILED))
echo -e "${GREEN}Testes aprovados: $TESTS_PASSED${NC}"
echo -e "${RED}Testes falhados: $TESTS_FAILED${NC}"
echo -e "Total de testes: $TOTAL_TESTS"
echo ""

if [ "$TESTS_FAILED" -eq 0 ]; then
    echo -e "${GREEN}✓ Sistema pronto para uso!${NC}"
    echo ""
    echo "Execute o backup manualmente:"
    echo "  $SCRIPT_DIR/backup_database.sh"
    exit 0
else
    echo -e "${RED}✗ Corrija os problemas antes de usar o sistema${NC}"
    echo ""
    echo "Revise as falhas acima e siga as instruções sugeridas"
    exit 1
fi