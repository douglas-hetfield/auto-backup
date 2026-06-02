#!/bin/bash

#==============================================================================
# Script de Backup Automatizado SQL Server (Docker) -> Google Drive
# Contexto: Proxmox + Alpine Linux + Docker (SQL Server 2022 Express)
# Versão: 1.0
# Descrição: Percorre todos os containers SQL Server, faz BACKUP DATABASE de
#            cada banco de usuário e sincroniza os arquivos .bak com o Google
#            Drive via rclone (modo sobrescrita).
#==============================================================================

# Carrega variáveis de ambiente
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"

if [ ! -f "$ENV_FILE" ]; then
    echo "ERRO: Arquivo de configuração não encontrado: $ENV_FILE"
    exit 1
fi

source "$ENV_FILE"

#==============================================================================
# CONFIGURAÇÕES
#==============================================================================

# Diretório base dos dados dos containers (onde estão as pastas backup/)
BACKUP_BASE_DIR="${BACKUP_BASE_DIR:-/var/lib/docker/sqldata}"

# Arquivos de senha
SECRET_SHARED="${SECRET_SHARED:-/var/lib/docker/sqldata/secrets/master_pass}"
SECRET_DEDICATED="${SECRET_DEDICATED:-/var/lib/docker/sqldata/secrets/master_pass_dedicated}"

# Caminho do sqlcmd dentro dos containers
SQLCMD="/opt/mssql-tools18/bin/sqlcmd"

# Caminho da pasta de backup dentro do container
CONTAINER_BACKUP_PATH="/var/opt/mssql/backup"

# Logs
LOG_BASE_DIR="${LOG_BASE_DIR:-/var/log/sqlbackup}"
DATE=$(date +"%Y%m%d_%H%M")
LOG_FILE="${LOG_BASE_DIR}/backup_${DATE}.log"

# rclone
GDRIVE_REMOTE="${GDRIVE_REMOTE:-gdrive}"
# GDRIVE_FOLDER pode ser vazio (envia direto para a raiz configurada via root_folder_id)
GDRIVE_FOLDER="${GDRIVE_FOLDER-}"

# Listas de containers vêm do .env (SHARED_CONTAINERS e DEDICATED_CONTAINERS)
# Validação: pelo menos uma das listas deve ter algum container
if [ "${#SHARED_CONTAINERS[@]}" -eq 0 ] && [ "${#DEDICATED_CONTAINERS[@]}" -eq 0 ]; then
    echo "ERRO: Nenhum container definido no .env (SHARED_CONTAINERS / DEDICATED_CONTAINERS)"
    exit 1
fi

# Contadores
TOTAL_DBS=0
SUCCESS_COUNT=0
FAILED_COUNT=0
FAILED_DBS=""

#==============================================================================
# FUNÇÕES
#==============================================================================

log() {
    local level=$1
    shift
    local message="$@"
    local timestamp=$(date +"%Y-%m-%d %H:%M:%S")
    local line="[${timestamp}] [${level}] ${message}"
    if [ "$level" = "ERROR" ] || [ "$level" = "WARN" ]; then
        echo "$line" | tee -a "$LOG_FILE" >&2
    else
        echo "$line" | tee -a "$LOG_FILE"
    fi
}

setup_directories() {
    mkdir -p "$LOG_BASE_DIR"
    if [ $? -ne 0 ]; then
        echo "ERRO: Falha ao criar diretório de logs: $LOG_BASE_DIR"
        exit 1
    fi
}

# Lê a senha do arquivo de secret
read_password() {
    local secret_file=$1
    if [ ! -f "$secret_file" ]; then
        log "ERROR" "Arquivo de senha não encontrado: $secret_file"
        return 1
    fi
    # Remove eventuais quebras de linha/espaços
    tr -d '\r\n' < "$secret_file"
}

# Verifica se o container está rodando
is_container_running() {
    local container=$1
    docker ps --format '{{.Names}}' | grep -q "^${container}$"
}

# Lista os bancos de usuário de um container
# Exclui bancos de sistema (database_id <= 4: master, tempdb, model, msdb)
# Retorno: 0 = sucesso (saída pode estar vazia se não houver bancos)
#          2 = falha de conexão/execução do sqlcmd
list_databases() {
    local container=$1
    local password=$2
    local output rc

    output=$(docker exec "$container" "$SQLCMD" \
        -S localhost -U SA -P "$password" -C -b -h -1 -W \
        -Q "SET NOCOUNT ON; SELECT name FROM sys.databases WHERE database_id > 4 AND state = 0;" \
        2>> "$LOG_FILE")
    rc=$?

    if [ $rc -ne 0 ]; then
        return 2
    fi

    echo "$output" | grep -v '^$'
    return 0
}

# Faz backup de um banco específico dentro do container
backup_database() {
    local container=$1
    local password=$2
    local db=$3

    local bak_name="backup_${db}.bak"
    local bak_path="${CONTAINER_BACKUP_PATH}/${bak_name}"

    log "INFO" "Backup: ${container} / ${db}"

    # FORMAT + INIT sobrescreve o arquivo (mantém apenas 1 backup set)
    # Express não suporta COMPRESSION, por isso não é usado
    # Sem -i: docker exec não deve consumir stdin do while read da chamada externa
    docker exec "$container" "$SQLCMD" \
        -S localhost -U SA -P "$password" -C -b \
        -Q "BACKUP DATABASE [${db}] TO DISK = N'${bak_path}' WITH FORMAT, INIT, NAME = N'${db}-full';" \
        >> "$LOG_FILE" 2>&1

    if [ $? -ne 0 ]; then
        log "ERROR" "Falha no backup: ${container} / ${db}"
        return 1
    fi

    local folder="${container#sql-}"
    local host_bak="${BACKUP_BASE_DIR}/${folder}/backup/${bak_name}"
    if [ -f "$host_bak" ]; then
        local size=$(du -h "$host_bak" | cut -f1)
        log "SUCCESS" "Concluído: ${container} / ${db} (${size})"
    else
        log "SUCCESS" "Concluído: ${container} / ${db}"
    fi

    return 0
}

# Processa todos os bancos de um container
process_container() {
    local container=$1
    local password=$2

    if ! is_container_running "$container"; then
        log "WARN" "Container não está rodando, ignorando: $container"
        return 0
    fi

    log "INFO" "=== Processando container: $container ==="

    local databases rc
    databases=$(list_databases "$container" "$password")
    rc=$?

    if [ $rc -ne 0 ]; then
        log "ERROR" "Falha ao listar bancos em $container (verifique senha/conexão SQL)"
        ((FAILED_COUNT++))
        FAILED_DBS="${FAILED_DBS}${container}/[conexao] "
        return 1
    fi

    if [ -z "$databases" ]; then
        log "WARN" "Nenhum banco de usuário encontrado em: $container"
        return 0
    fi

    while IFS= read -r db; do
        # Trim apenas espaços/tabs nas bordas, preservando espaços internos
        db="${db#"${db%%[![:space:]]*}"}"
        db="${db%"${db##*[![:space:]]}"}"
        [ -z "$db" ] && continue
        ((TOTAL_DBS++))
        if backup_database "$container" "$password" "$db"; then
            ((SUCCESS_COUNT++))
        else
            ((FAILED_COUNT++))
            FAILED_DBS="${FAILED_DBS}${container}/${db} "
        fi
    done <<< "$databases"
}

# Upload de todos os .bak para uma única pasta no Google Drive.
# O destino final é configurado via root_folder_id no rclone; GDRIVE_FOLDER
# pode ficar vazio (envia para a raiz do remote) ou ser uma subpasta.
upload_to_gdrive() {
    log "INFO" "=== Iniciando upload para Google Drive ==="

    if ! command -v rclone &> /dev/null; then
        log "ERROR" "rclone não está instalado"
        return 1
    fi

    local all_containers=("${SHARED_CONTAINERS[@]}" "${DEDICATED_CONTAINERS[@]}")
    local dest="${GDRIVE_REMOTE}:${GDRIVE_FOLDER}"
    local uploaded=0
    local failed=0

    for container in "${all_containers[@]}"; do
        local folder="${container#sql-}"
        local src="${BACKUP_BASE_DIR}/${folder}/backup"

        if [ ! -d "$src" ]; then
            continue
        fi

        # Só envia se houver arquivos backup_*.bak
        if ! ls "${src}"/backup_*.bak &> /dev/null; then
            continue
        fi

        log "INFO" "Enviando arquivos de: ${folder} -> ${dest}"
        rclone copy "$src" "$dest" --include "backup_*.bak" >> "$LOG_FILE" 2>&1

        if [ $? -eq 0 ]; then
            log "SUCCESS" "Upload OK: ${folder}"
            ((uploaded++))
        else
            log "ERROR" "Falha no upload: ${folder}"
            ((failed++))
        fi
    done

    log "INFO" "Containers enviados: $uploaded | falhas: $failed"
}

cleanup_old_logs() {
    local days=${LOG_RETENTION_DAYS:-30}
    local count=$(find "$LOG_BASE_DIR" -type f -name "*.log" -mtime +$days 2>/dev/null | wc -l)
    if [ "$count" -gt 0 ]; then
        find "$LOG_BASE_DIR" -type f -name "*.log" -mtime +$days -delete
        log "INFO" "Removidos $count log(s) antigo(s)"
    fi
}

print_summary() {
    log "INFO" "=========================================="
    log "INFO" "RELATÓRIO DE BACKUP"
    log "INFO" "=========================================="
    log "INFO" "Total de bancos: $TOTAL_DBS"
    log "INFO" "Sucessos: $SUCCESS_COUNT"
    log "INFO" "Falhas: $FAILED_COUNT"
    if [ "$FAILED_COUNT" -gt 0 ]; then
        log "ERROR" "Bancos com falha: $FAILED_DBS"
    fi
    log "INFO" "=========================================="
}

#==============================================================================
# FUNÇÃO PRINCIPAL
#==============================================================================

main() {
    setup_directories

    log "INFO" "=========================================="
    log "INFO" "Iniciando backup automático SQL Server"
    log "INFO" "=========================================="

    # Lê as senhas
    PASS_SHARED=$(read_password "$SECRET_SHARED") || exit 1
    PASS_DEDICATED=$(read_password "$SECRET_DEDICATED") || exit 1

    # Processa containers compartilhados
    for container in "${SHARED_CONTAINERS[@]}"; do
        process_container "$container" "$PASS_SHARED"
    done

    # Processa containers dedicados
    for container in "${DEDICATED_CONTAINERS[@]}"; do
        process_container "$container" "$PASS_DEDICATED"
    done

    # Upload para o Google Drive
    if [ "$ENABLE_GDRIVE" == "true" ]; then
        upload_to_gdrive
    else
        log "INFO" "Upload para Google Drive desabilitado (ENABLE_GDRIVE != true)"
    fi

    cleanup_old_logs
    print_summary

    [ "$FAILED_COUNT" -gt 0 ] && exit 1 || exit 0
}

main "$@"