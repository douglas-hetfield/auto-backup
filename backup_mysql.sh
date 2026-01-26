#!/bin/bash

#==============================================================================
# Script de Backup Automatizado MySQL → Google Drive
# Autor: Sistema de Backup
# Versão: 1.0
# Descrição: Realiza backup de todos os bancos MySQL e sincroniza com Google Drive
#==============================================================================

# Carrega variáveis de ambiente
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"

if [ ! -f "$ENV_FILE" ]; then
    echo "ERRO: Arquivo de configuração não encontrado: $ENV_FILE"
    exit 1
fi

source "$ENV_FILE"

# Configurações de diretórios
BACKUP_DIR="${BACKUP_BASE_DIR:-/var/www/backups/base_dados}"
LOG_DIR="${LOG_BASE_DIR:-/var/www/backups/logs}"
DATE=$(date +"%Y%m%d_%H%M")
DATE_FOLDER=$(date +"%Y-%m")
LOG_FILE="${LOG_DIR}/backup_${DATE}.log"

# Contadores
TOTAL_DBS=0
SUCCESS_COUNT=0
FAILED_COUNT=0
FAILED_DBS=""

# Bancos de dados do sistema a serem ignorados
EXCLUDE_DBS="information_schema performance_schema mysql sys phpmyadmin"

#==============================================================================
# FUNÇÕES
#==============================================================================

# Função de log
log() {
    local level=$1
    shift
    local message="$@"
    local timestamp=$(date +"%Y-%m-%d %H:%M:%S")
    echo "[${timestamp}] [${level}] ${message}" | tee -a "$LOG_FILE"
}

# Cria estrutura de diretórios
setup_directories() {
    log "INFO" "Criando estrutura de diretórios..."
    mkdir -p "$BACKUP_DIR"
    mkdir -p "$LOG_DIR"
    
    if [ $? -eq 0 ]; then
        log "SUCCESS" "Diretórios criados com sucesso"
        return 0
    else
        log "ERROR" "Falha ao criar diretórios"
        return 1
    fi
}

# Lista todos os bancos de dados
list_databases() {
    local dbs=$(mysql -u "$MYSQL_USER" -p"$MYSQL_PASSWORD" -h "$MYSQL_HOST" -e "SHOW DATABASES;" 2>/dev/null | grep -Ev "Database|${EXCLUDE_DBS// /|}")
    
    if [ $? -ne 0 ]; then
        log "ERROR" "Falha ao conectar no MySQL ou listar bancos de dados"
        return 1
    fi
    
    echo "$dbs"
    return 0
}

# Realiza backup de um banco específico
backup_database() {
    local db=$1
    local sql_file="${BACKUP_DIR}/${db}_temp.sql"
    local zip_file="${BACKUP_DIR}/backup_${db}.zip"
    
    log "INFO" "Iniciando backup do banco: $db"
    
    # Realiza o dump
    mysqldump -u "$MYSQL_USER" -p"$MYSQL_PASSWORD" -h "$MYSQL_HOST" \
        --single-transaction \
        --routines \
        --triggers \
        --events \
        "$db" > "$sql_file" 2>> "$LOG_FILE"
    
    if [ $? -ne 0 ]; then
        log "ERROR" "Falha no dump do banco: $db"
        rm -f "$sql_file" 2>/dev/null
        return 1
    fi
    
    # Verifica se o arquivo foi criado e não está vazio
    if [ ! -s "$sql_file" ]; then
        log "ERROR" "Arquivo de dump vazio ou não criado: $db"
        rm -f "$sql_file" 2>/dev/null
        return 1
    fi
    
    log "INFO" "Compactando backup: $db"
    
    # Compacta o arquivo
    zip -q "$zip_file" "$sql_file"
    
    if [ $? -ne 0 ]; then
        log "ERROR" "Falha ao compactar backup: $db"
        rm -f "$sql_file" "$zip_file" 2>/dev/null
        return 1
    fi
    
    # Remove arquivo SQL não compactado
    rm -f "$sql_file"
    
    local size=$(du -h "$zip_file" | cut -f1)
    log "SUCCESS" "Backup concluído: $db (Tamanho: $size)"
    
    return 0
}

# Upload para Google Drive
upload_to_gdrive() {
    log "INFO" "Iniciando upload para Google Drive..."
    
    # Verifica se rclone está instalado
    if ! command -v rclone &> /dev/null; then
        log "ERROR" "rclone não está instalado"
        return 1
    fi
    
    # Cria pasta no Google Drive se não existir
    local remote_path="${GDRIVE_REMOTE}:${GDRIVE_FOLDER}"
    
    # Upload de todos os arquivos .zip
    local files_uploaded=0
    for file in ${BACKUP_DIR}/*.zip; do
        if [ -f "$file" ]; then
            local filename=$(basename "$file")
            log "INFO" "Uploading: $filename"
            
            rclone copy "$file" "$remote_path" --progress 2>> "$LOG_FILE"
            
            if [ $? -eq 0 ]; then
                log "SUCCESS" "Upload concluído: $filename"
                ((files_uploaded++))
            else
                log "ERROR" "Falha no upload: $filename"
            fi
        fi
    done
    
    if [ $files_uploaded -gt 0 ]; then
        log "INFO" "Total de arquivos enviados: $files_uploaded"
        return 0
    else
        log "ERROR" "Nenhum arquivo foi enviado para o Google Drive"
        return 1
    fi
}

# Limpeza de backups antigos (local)
cleanup_old_backups() {
    log "INFO" "Modo de sobrescrita ativado - limpeza automática desabilitada"
    # Não é necessário limpar arquivos antigos pois sempre sobrescreve o mesmo arquivo
    #local days=${RETENTION_DAYS:-15}
    #log "INFO" "Removendo backups locais com mais de $days dias..."
    
    #local count=$(find "$BACKUP_DIR" -type f -name "*.zip" -mtime +$days | wc -l)
    
    #if [ $count -gt 0 ]; then
    #    find "$BACKUP_DIR" -type f -name "*.zip" -mtime +$days -delete
    #    log "SUCCESS" "Removidos $count arquivo(s) antigo(s)"
    #else
    #    log "INFO" "Nenhum arquivo antigo para remover"
    #fi
}

# Limpeza de logs antigos
cleanup_old_logs() {
    local days=${LOG_RETENTION_DAYS:-30}
    log "INFO" "Removendo logs com mais de $days dias..."
    
    local count=$(find "$LOG_DIR" -type f -name "*.log" -mtime +$days | wc -l)
    
    if [ $count -gt 0 ]; then
        find "$LOG_DIR" -type f -name "*.log" -mtime +$days -delete
        log "SUCCESS" "Removidos $count log(s) antigo(s)"
    else
        log "INFO" "Nenhum log antigo para remover"
    fi
}

# Relatório final
print_summary() {
    log "INFO" "=========================================="
    log "INFO" "RELATÓRIO DE BACKUP - $(date +"%Y-%m-%d %H:%M:%S")"
    log "INFO" "=========================================="
    log "INFO" "Total de bancos: $TOTAL_DBS"
    log "INFO" "Sucessos: $SUCCESS_COUNT"
    log "INFO" "Falhas: $FAILED_COUNT"
    
    if [ $FAILED_COUNT -gt 0 ]; then
        log "ERROR" "Bancos com falha: $FAILED_DBS"
    fi
    
    log "INFO" "=========================================="
}

#==============================================================================
# FUNÇÃO PRINCIPAL
#==============================================================================

main() {
    log "INFO" "=========================================="
    log "INFO" "Iniciando processo de backup automático"
    log "INFO" "=========================================="
    
    # Setup inicial
    setup_directories || exit 1
    
    # Modo de listagem apenas
    if [ "$1" == "--list" ]; then
        log "INFO" "Modo: Listagem de bancos de dados"
        databases=$(list_databases)
        if [ $? -eq 0 ]; then
            echo "$databases"
            exit 0
        else
            exit 1
        fi
    fi
    
    # Backup de banco específico
    if [ "$1" == "--database" ] && [ -n "$2" ]; then
        log "INFO" "Modo: Backup de banco específico - $2"
        backup_database "$2"
        exit $?
    fi
    
    # Lista bancos de dados
    databases=$(list_databases)
    if [ $? -ne 0 ]; then
        log "ERROR" "Não foi possível obter lista de bancos de dados"
        exit 1
    fi
    
    # Conta total de bancos
    TOTAL_DBS=$(echo "$databases" | wc -l)
    log "INFO" "Total de bancos encontrados: $TOTAL_DBS"
    
    # Backup de cada banco
    for db in $databases; do
        if backup_database "$db"; then
            ((SUCCESS_COUNT++))
        else
            ((FAILED_COUNT++))
            FAILED_DBS="${FAILED_DBS}${db} "
        fi
    done
    
    # Upload para Google Drive
    if [ "$ENABLE_GDRIVE" == "true" ]; then
        upload_to_gdrive
    else
        log "INFO" "Upload para Google Drive desabilitado"
    fi
    
    # Limpeza de arquivos antigos
    cleanup_old_backups
    cleanup_old_logs
    
    # Relatório final
    print_summary
    
    # Exit code baseado em falhas
    if [ $FAILED_COUNT -gt 0 ]; then
        exit 1
    else
        exit 0
    fi
}

#==============================================================================
# EXECUÇÃO
#==============================================================================

main "$@"