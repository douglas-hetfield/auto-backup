# Sistema de Backup Automatizado SQL Server (Docker) → Google Drive

Sistema para backup automático de bancos SQL Server hospedados em containers Docker, com upload dos arquivos `.bak` para uma pasta única no Google Drive via rclone.

Contexto-alvo: **Proxmox + Alpine Linux + Docker** (SQL Server 2022 Express).

---

## Índice

- [Recursos](#recursos)
- [Pré-requisitos](#pré-requisitos)
- [Instalação](#instalação)
- [Configuração (.env)](#configuração-env)
- [Uso](#uso)
- [Como funciona](#como-funciona)
- [Monitoramento](#monitoramento)
- [Solução de Problemas](#solução-de-problemas)
- [Estrutura de Arquivos](#estrutura-de-arquivos)

---

## Recursos

- Varre todos os containers SQL Server listados no `.env`
- Backup de todos os bancos de usuário (exclui `master`, `tempdb`, `model`, `msdb`)
- Suporte a containers **compartilhados** (uma senha) e **dedicados** (outra senha)
- Arquivos gerados com nome fixo `backup_<nome_do_banco>.bak` (sobrescritos a cada execução — mantém apenas o backup mais recente)
- Upload **flat** para uma única pasta do Google Drive (configurada via `root_folder_id` do rclone)
- Logs detalhados por execução
- Limpeza automática de logs antigos
- Validação prévia via `test_backup.sh`

---

## Pré-requisitos

- Alpine Linux (ou compatível) com Docker em execução
- Containers SQL Server já criados com:
  - `sqlcmd` em `/opt/mssql-tools18/bin/sqlcmd`
  - Volume mapeando `/var/opt/mssql/backup` (dentro do container) para um diretório no host
  - Arquivos de senha do SA acessíveis no host (`SECRET_SHARED` / `SECRET_DEDICATED`)
- `bash`, `curl` e `rclone` no host

```sh
apk add --no-cache bash curl rclone
```

Caso o pacote `rclone` do Alpine seja muito antigo, use o instalador oficial:
```sh
curl https://rclone.org/install.sh | sh
```

---

## Instalação

### 1. Clonar e posicionar os scripts
```sh
cd /opt
git clone <repo> auto-backup
cd auto-backup
chmod +x backup_database.sh test_backup.sh install.sh
```

### 2. (Opcional) Rodar o instalador interativo
```sh
sudo ./install.sh
```
O `install.sh` cria os diretórios padrão (`/opt/sqlbackup`, `/var/log/sqlbackup`), gera um `.env` inicial e valida dependências. Se você já tem o `.env`, pode pular esta etapa.

### 3. Configurar o rclone para o Google Drive (uma vez)
```sh
rclone config
```
Passos:
- `n` (new remote)
- name: `gdrive`
- Storage: `Google Drive`
- `client_id` / `client_secret`: em branco (ou usar os seus)
- scope: **`1` (drive — Full access)** — necessário para acessar "Compartilhados comigo"
- `root_folder_id`: cole o ID da pasta destino no Drive (peguei da URL `https://drive.google.com/drive/folders/<ID_AQUI>`)
- `service_account_file`: em branco
- Auto config: **`n`** (servidor sem GUI) — copie a URL exibida, abra em outro computador, autentique e cole o code de volta
- Confirme o remote

Teste:
```sh
rclone lsf gdrive: --max-depth 1
```
Você deve enxergar o conteúdo da pasta apontada pelo `root_folder_id`.

### 4. Validar o ambiente
```sh
./test_backup.sh
```
O script verifica: presença de `.env`, permissões, containers rodando, conectividade com SQL Server, contagem de bancos, escrita nas pastas de backup, espaço em disco e configuração do rclone.

---

## Configuração (.env)

Exemplo completo (ajuste para o seu ambiente):

```sh
# Diretórios
BACKUP_BASE_DIR=/usr/local/var/www/auto-backup/backups/base_dados
LOG_BASE_DIR=/usr/local/var/www/auto-backup/backups/logs
LOG_RETENTION_DAYS=15

# Google Drive (rclone)
ENABLE_GDRIVE=true
GDRIVE_REMOTE=gdrive
# Vazio = envia direto para a raiz definida pelo root_folder_id do rclone
GDRIVE_FOLDER=

# Senhas do SA (uma por grupo de containers)
SECRET_SHARED="/var/lib/docker/sqldata/secrets/master_pass"
SECRET_DEDICATED="/var/lib/docker/sqldata/secrets/master_pass_dedicated"

# Containers compartilhados (usam SECRET_SHARED)
SHARED_CONTAINERS=(
    sql-shared-01
    sql-shared-02
    sql-shared-03
    sql-shared-04
    sql-shared-05
    sql-shared-06
    sql-shared-07
    sql-shared-08
    sql-shared-09
    sql-shared-10-homolog
)

# Containers dedicados (usam SECRET_DEDICATED)
DEDICATED_CONTAINERS=(
    sql-viacapi
    sql-bonitoway
    sql-apresentacaoinbuzios
    sql-sve
    sql-naturezatour
    sql-ygarape
    sql-roteirobonito
)
```

### Adicionar um novo container
Basta acrescentar a linha na lista correta (`SHARED_CONTAINERS` ou `DEDICATED_CONTAINERS`). Nenhum script precisa ser alterado.

### Mapeamento de pastas
O script espera encontrar os arquivos gerados em:
```
${BACKUP_BASE_DIR}/<folder>/backup/backup_<db>.bak
```
onde `<folder>` é o nome do container sem o prefixo `sql-` (ex.: `sql-shared-03` → `shared-03`).

Garanta que cada container tenha um volume montando `/var/opt/mssql/backup` exatamente para `${BACKUP_BASE_DIR}/<folder>/backup` no host.

### Permissões
```sh
chmod 600 .env
```

---

## Uso

### Backup manual
```sh
./backup_database.sh
```

### Agendar via cron (exemplo: diariamente às 3h)
```sh
crontab -e
```
Adicione:
```
0 3 * * * /opt/auto-backup/backup_database.sh
```

---

## Como funciona

1. Carrega `.env` (lista de containers, senhas, destino do Drive).
2. Para cada container rodando:
   - Conecta no SQL Server via `sqlcmd` dentro do container.
   - Lista bancos de usuário (`database_id > 4 AND state = 0`).
   - Para cada banco: executa `BACKUP DATABASE [<db>] TO DISK = N'/var/opt/mssql/backup/backup_<db>.bak' WITH FORMAT, INIT, NAME = N'<db>-full';`
   - `FORMAT + INIT` sobrescreve sempre o mesmo arquivo (mantém apenas 1 backup set).
3. Após processar todos os containers, se `ENABLE_GDRIVE=true`:
   - Para cada pasta de backup, envia `backup_*.bak` para `${GDRIVE_REMOTE}:${GDRIVE_FOLDER}`.
   - Como todos os nomes são únicos (`backup_<db>.bak`), todos convivem em uma pasta única no Drive.
4. Limpa logs com mais de `LOG_RETENTION_DAYS` dias.
5. Imprime sumário (total / sucessos / falhas) e retorna exit code 0 ou 1.

> **SQL Server Express não suporta compressão de backup** — por isso o script não usa `WITH COMPRESSION`.

---

## Monitoramento

### Log da última execução
```sh
ls -t ${LOG_BASE_DIR}/backup_*.log | head -1 | xargs tail -f
```

### Ver erros / falhas
```sh
LOG=$(ls -t ${LOG_BASE_DIR}/backup_*.log | head -1)
grep -E "ERROR|Falha" "$LOG"
```

### Conferir o que foi enviado ao Drive
```sh
rclone lsf gdrive: --max-depth 1 | grep backup_
```

### Tamanhos locais
```sh
du -h ${BACKUP_BASE_DIR}/*/backup/backup_*.bak 2>/dev/null
```

---

## Solução de Problemas

### "STATS parameter not within range"
Resolvido. O script não usa mais `STATS = 0` (era inválido para o sqlcmd da versão atual).

### Só o primeiro banco de cada container é processado
Resolvido. `docker exec -i` consumia o stdin do `while read` do loop externo. Hoje as chamadas usam `docker exec` (sem `-i`) já que `-Q` não exige stdin.

### "Falha no upload" para o Drive
1. Veja o motivo real do rclone:
   ```sh
   rclone copy ${BACKUP_BASE_DIR}/<folder>/backup gdrive: --include "backup_*.bak" -vv
   ```
2. Verifique a config: `rclone config show gdrive`
   - `scope` precisa ser `drive` (não `drive.file`) para acessar pasta "Compartilhada comigo"
   - `root_folder_id` deve apontar para a pasta real (não para um atalho)
3. Reautenticar:
   ```sh
   rclone config reconnect gdrive:
   ```

### Arquivos `.bak` antigos ainda no Drive
Versões anteriores deste script geravam `<db>.bak` (sem prefixo). Esses arquivos permanecem no Drive até serem removidos manualmente. Para limpar:
```sh
rclone delete gdrive: --include "*.bak" --exclude "backup_*.bak" --dry-run
# revise e rode sem --dry-run
```

### Container não está rodando
O script ignora com WARN. Inicie o container:
```sh
docker start <nome-do-container>
```

### Falha na listagem de bancos (senha incorreta)
O log mostra `ERROR Falha ao listar bancos em <container>`. Confira o conteúdo do arquivo apontado por `SECRET_SHARED` / `SECRET_DEDICATED` e teste manualmente:
```sh
docker exec <container> /opt/mssql-tools18/bin/sqlcmd -S localhost -U SA -P "<senha>" -C -Q "SELECT 1"
```

### Espaço em disco
```sh
df -h ${BACKUP_BASE_DIR}
```
Como cada banco mantém apenas um `.bak` (sobrescrito), o consumo não cresce com o tempo — só com o tamanho dos bancos.

---

## Estrutura de Arquivos

```
/opt/auto-backup/
├── backup_database.sh        # Script principal
├── test_backup.sh            # Validador do ambiente
├── install.sh                # Instalador interativo (opcional)
├── .env                      # Configuração (NÃO versionar — chmod 600)
└── README.md

${BACKUP_BASE_DIR}/           # Pastas montadas como volume nos containers
├── shared-01/backup/
│   ├── backup_DB1.bak
│   └── backup_DB2.bak
├── shared-02/backup/
│   └── ...
└── viacapi/backup/
    └── ...

${LOG_BASE_DIR}/              # Logs de cada execução
├── backup_20260601_0300.log
├── backup_20260602_0300.log
└── ...

Google Drive (root_folder_id):
backup_DB1.bak
backup_DB2.bak
backup_OutroBanco.bak
...                           # Tudo flat, sem subpastas
```

---

## Segurança

- `.env` com permissão `600`
- Senhas do SA em arquivos separados (`SECRET_SHARED` / `SECRET_DEDICATED`), nunca em commit
- Logs não imprimem senhas
- Recomenda-se usar contas/credenciais distintas para cada grupo de containers
