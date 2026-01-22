🗄️ Sistema de Backup Automatizado MySQL → Google Drive
Sistema completo e robusto para backup automático de bancos de dados MySQL com sincronização no Google Drive.

📋 Índice

Recursos
Pré-requisitos
Instalação
Configuração
Uso
Monitoramento
Solução de Problemas


✨ Recursos

✅ Backup automático de todos os bancos MySQL
✅ Exclusão automática de bancos de sistema
✅ Compactação em ZIP
✅ Upload automático para Google Drive
✅ Sistema de logs detalhado
✅ Tratamento individual de erros
✅ Limpeza automática de backups antigos
✅ Execução via cronjob
✅ Modo manual e automático
✅ Segurança com arquivo .env


🔧 Pré-requisitos
Pacotes necessários
bash# Atualizar sistema
sudo apt update && sudo apt upgrade -y

# Instalar dependências
sudo apt install -y mysql-client zip unzip curl
Verificar instalação do MySQL Client
bashmysql --version
# Deve retornar algo como: mysql  Ver 8.0.x

📦 Instalação
1. Criar estrutura de diretórios
bash# Criar diretórios principais
sudo mkdir -p /var/www/backups/{base_dados,logs,config}

# Navegar para o diretório
cd /var/www/backups
2. Criar os arquivos
Criar o script principal:
bashsudo nano backup_mysql.sh
Cole o conteúdo do script backup_mysql.sh e salve (Ctrl+X, Y, Enter).
Criar arquivo de configuração:
bashsudo nano config/.env
Cole o conteúdo do .env.example, ajuste as credenciais e salve.
3. Definir permissões
bash# Tornar script executável
sudo chmod +x backup_mysql.sh

# Proteger arquivo de configuração
sudo chmod 600 config/.env

# Definir proprietário (ajuste para seu usuário)
sudo chown -R www-data:www-data /var/www/backups

⚙️ Configuração
1. Configurar credenciais MySQL
Edite o arquivo config/.env:
bashsudo nano config/.env
envMYSQL_USER=seu_usuario
MYSQL_PASSWORD=sua_senha_segura
MYSQL_HOST=localhost
2. Configurar Google Drive (rclone)
Instalação do rclone
bash# Instalar rclone
curl https://rclone.org/install.sh | sudo bash

# Verificar instalação
rclone version
Configurar remote do Google Drive
bash# Iniciar configuração
rclone config

# Seguir os passos:
# n) New remote
# name> gdrive
# Storage> 18 (Google Drive)
# client_id> (deixe em branco - Enter)
# client_secret> (deixe em branco - Enter)
# scope> 1 (Full access)
# root_folder_id> (deixe em branco - Enter)
# service_account_file> (deixe em branco - Enter)
# Edit advanced config? n
# Use auto config? n (em servidor sem interface gráfica)
IMPORTANTE: Como o servidor não tem interface gráfica, você precisará:

O rclone mostrará uma URL
Copie essa URL
Abra em um navegador no seu computador
Faça login com sua conta Google
Autorize o acesso
Copie o código de verificação
Cole no terminal do servidor

bash# Continuar configuração
# Configure this as a team drive? n
# Yes this is OK? y
# q) Quit config
Testar conexão com Google Drive
bash# Listar arquivos do Google Drive
rclone ls gdrive:

# Criar pasta de teste
rclone mkdir gdrive:Backups/MySQL

# Verificar se foi criada
rclone lsd gdrive:Backups/
3. Ajustar configurações no .env
bashsudo nano config/.env
env# Habilitar Google Drive
ENABLE_GDRIVE=true

# Nome do remote (mesmo nome usado no rclone config)
GDRIVE_REMOTE=gdrive

# Pasta no Google Drive
GDRIVE_FOLDER=Backups/MySQL

# Retenção local (dias)
RETENTION_DAYS=15

# Retenção de logs (dias)
LOG_RETENTION_DAYS=30

🚀 Uso
Modo Manual
1. Backup completo (todos os bancos)
bashcd /var/www/backups
sudo ./backup_mysql.sh
2. Listar bancos disponíveis
bashsudo ./backup_mysql.sh --list
3. Backup de banco específico
bashsudo ./backup_mysql.sh --database nome_do_banco
Modo Automático (Cronjob)
Configurar execução diária às 3h
bash# Editar crontab
sudo crontab -e

# Adicionar linha:
0 3 * * * /var/www/backups/backup_mysql.sh >> /var/www/backups/logs/cron.log 2>&1
Outras opções de agendamento
bash# Executar a cada 6 horas
0 */6 * * * /var/www/backups/backup_mysql.sh

# Executar às 2h e 14h todos os dias
0 2,14 * * * /var/www/backups/backup_mysql.sh

# Executar apenas de segunda a sexta às 3h
0 3 * * 1-5 /var/www/backups/backup_mysql.sh
Verificar cronjobs ativos
bashsudo crontab -l

📊 Monitoramento
Visualizar logs em tempo real
bash# Último log
tail -f /var/www/backups/logs/backup_*.log

# Log específico
tail -f /var/www/backups/logs/backup_20240121_0300.log
Ver últimos backups criados
bashls -lht /var/www/backups/base_dados/ | head -10
Verificar espaço em disco
bashdf -h /var/www/backups
du -sh /var/www/backups/*
Exemplo de log bem-sucedido
[2024-01-21 03:00:01] [INFO] ==========================================
[2024-01-21 03:00:01] [INFO] Iniciando processo de backup automático
[2024-01-21 03:00:01] [INFO] ==========================================
[2024-01-21 03:00:02] [INFO] Listando bancos de dados disponíveis...
[2024-01-21 03:00:02] [INFO] Total de bancos encontrados: 5
[2024-01-21 03:00:02] [INFO] Iniciando backup do banco: meu_site
[2024-01-21 03:00:15] [INFO] Compactando backup: meu_site
[2024-01-21 03:00:18] [SUCCESS] Backup concluído: meu_site (Tamanho: 45M)
[2024-01-21 03:00:18] [INFO] Iniciando upload para Google Drive...
[2024-01-21 03:00:25] [SUCCESS] Upload concluído: meu_site_20240121_0300.zip
[2024-01-21 03:00:26] [INFO] Removendo backups locais com mais de 15 dias...
[2024-01-21 03:00:26] [SUCCESS] Removidos 3 arquivo(s) antigo(s)
[2024-01-21 03:00:26] [INFO] ==========================================
[2024-01-21 03:00:26] [INFO] RELATÓRIO DE BACKUP - 2024-01-21 03:00:26
[2024-01-21 03:00:26] [INFO] Total de bancos: 5
[2024-01-21 03:00:26] [INFO] Sucessos: 5
[2024-01-21 03:00:26] [INFO] Falhas: 0
[2024-01-21 03:00:26] [INFO] ==========================================

🔍 Solução de Problemas
Problema: "Arquivo de configuração não encontrado"
Solução:
bash# Verificar se .env existe
ls -la /var/www/backups/config/.env

# Se não existir, criar
sudo cp .env.example config/.env
sudo nano config/.env
Problema: "Falha ao conectar no MySQL"
Soluções:
bash# Testar conexão manualmente
mysql -u seu_usuario -p -h localhost

# Verificar se usuário tem permissões
mysql -u root -p
GRANT SELECT, LOCK TABLES ON *.* TO 'seu_usuario'@'localhost';
FLUSH PRIVILEGES;
Problema: "rclone não está instalado"
Solução:
bash# Reinstalar rclone
curl https://rclone.org/install.sh | sudo bash
rclone version
Problema: "Falha no upload para Google Drive"
Soluções:
bash# Testar conexão
rclone ls gdrive:

# Se falhar, reconfigurar
rclone config reconnect gdrive:

# Verificar logs detalhados
rclone copy arquivo.zip gdrive:Backups/MySQL -v
Problema: Espaço em disco insuficiente
Solução:
bash# Verificar espaço
df -h

# Reduzir retenção no .env
RETENTION_DAYS=7

# Limpar manualmente backups antigos
find /var/www/backups/base_dados -name "*.zip" -mtime +7 -delete
Problema: Backup muito lento
Otimizações:
bash# Adicionar compressão mais rápida (no script, linha do zip)
# Trocar: zip -q
# Por: zip -1 -q  (compressão rápida)

# Usar mysqldump com compressão
mysqldump ... | gzip > arquivo.sql.gz

📁 Estrutura de Arquivos
/var/www/backups/
├── backup_mysql.sh              # Script principal
├── config/
│   ├── .env                     # Configurações (NÃO versionar)
│   └── .env.example             # Exemplo de configuração
├── base_dados/                  # Backups locais temporários
│   ├── banco1_20240121_0300.zip
│   ├── banco2_20240121_0300.zip
│   └── ...
└── logs/                        # Logs de execução
    ├── backup_20240121_0300.log
    ├── backup_20240120_0300.log
    └── cron.log

🔐 Segurança
Boas práticas implementadas

Credenciais em arquivo separado (.env)
Permissões restritas (chmod 600)
Logs sem senhas
Conexão segura com MySQL

Recomendações adicionais
bash# Criar usuário MySQL dedicado apenas para backups
CREATE USER 'backup_user'@'localhost' IDENTIFIED BY 'senha_forte';
GRANT SELECT, LOCK TABLES, SHOW VIEW, TRIGGER ON *.* TO 'backup_user'@'localhost';
FLUSH PRIVILEGES;

📞 Suporte
Comandos úteis de diagnóstico
bash# Verificar status do MySQL
sudo systemctl status mysql

# Ver processos MySQL ativos
ps aux | grep mysql

# Testar script em modo debug
bash -x /var/www/backups/backup_mysql.sh --list

🎯 Checklist de Instalação

 Instalou dependências (mysql-client, zip, rclone)
 Criou estrutura de diretórios
 Copiou script backup_mysql.sh
 Criou arquivo config/.env com credenciais
 Configurou permissões (chmod +x, chmod 600)
 Configurou rclone com Google Drive
 Testou backup manual
 Verificou upload no Google Drive
 Configurou cronjob
 Testou visualização de logs


Versão: 1.0
Última atualização: Janeiro 2024