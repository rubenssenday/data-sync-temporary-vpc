# Guia de Migração ElastiCache (Redis) Cross-Account com Worker Transitório

Este guia descreve o processo de cópia/migração de dados entre instâncias ou clusters do **Amazon ElastiCache (Redis)** da **Conta A (Origem: onnibank)** para a **Conta B (Destino: ringgo-prd)** utilizando uma **EC2 Worker de Migração** hospedada na VPC Transitória.

---

## 📌 Contexto da Arquitetura

Como o AWS DataSync não suporta Redis/bancos de dados em memória, a abordagem recomendada utiliza a **VPC Transitória** como uma ponte segura entre as duas contas:

```
[Conta A - Origem]                     [Conta B - Destino]
+-------------------+                  +---------------------+
| VPC Origem        |                  | VPC Definitiva      |
| ElastiCache Redis |                  | ElastiCache Redis   |
| (ex: 10.100.12.0) |                  | (ex: 10.100.0.0/16) |
+---------^---------+                  +----------^----------+
          | (VPC Peering)                         | (VPC Peering)
          +---------------+         +-------------+
                          |         |
                  +-------v---------v-------+
                  | VPC Transitória         |
                  | (172.31.0.0/24)         |
                  | EC2 Worker de Migração  |
                  | (RedisShake / RIOT /    |
                  |  redis-cli + SSM)       |
                  +-------------------------+
```

* **Conta A (Origem)**:
  * Account ID: `352187878218` (Profile: `onnibank`)
  * VPC Origem: `vpc-09033f0343de5abe1` (`10.100.12.0/22`)
  * Route Table Subnet Redis: `rtb-0a29b4cc7c7f0230f`
* **Conta B (Destino e Orquestradora)**:
  * Account ID: `741796255940` (Profile: `ringgo-prd`)
  * VPC Transitória: `172.31.0.0/24` (Subnet `172.31.0.0/26`)
  * VPC Definitiva: `vpc-0702cf649d7d41c9a` (`10.100.0.0/16`)
  * Route Table Subnet Redis Destino: `rtb-0d1ccf76c8afbc49c`
  * Worker: EC2 Amazon Linux 2023 com AWS Systems Manager (SSM) habilitado.

---

## 🔒 Passo 1: Pré-requisitos de Security Group nos ElastiCaches

Antes de iniciar a cópia, os Security Groups dos seus clusters ElastiCache precisam permitir tráfego de entrada na porta **6379** a partir da subnet transitória (`172.31.0.0/26`):

1. **No ElastiCache da Conta A (Origem)**:
   * Adicione regra Inbound:
     * **Tipo**: Custom TCP
     * **Porta**: `6379`
     * **Origem**: `172.31.0.0/26` (Subnet Transitória)
2. **No ElastiCache da Conta B (Destino)**:
   * Adicione regra Inbound:
     * **Tipo**: Custom TCP
     * **Porta**: `6379`
     * **Origem**: `172.31.0.0/26` (Subnet Transitória)

---

## 🚀 Passo 2: Provisionar a Infraestrutura com Terraform

No terminal, dentro da pasta `redis-copy`:

```powershell
# Caso já possua estado local e queira migrar para o S3:
terraform init -migrate-state

# Ou para inicializar normalmente:
terraform init

terraform apply -auto-approve
```

Ao concluir, você verá nos outputs o comando direto de conexão via SSM:
```text
migrator_instance_id = "i-0xxxxxxxxxxxxxxxxx"
ssm_connect_command  = "aws ssm start-session --target i-0xxxxxxxxxxxxxxxxx --profile ringgo-prd --region sa-east-1"
```

---

## 🔑 Passo 3: Conectar no Worker de Migração

Você pode se conectar instantaneamente via **AWS Systems Manager (SSM)**, sem necessidade de abrir porta 22 ou configurar chaves SSH:

```powershell
aws ssm start-session --target $(terraform output -raw migrator_instance_id) --profile ringgo-prd --region sa-east-1
```

Ao entrar no terminal do Linux:
```bash
sudo su - ec2-user
cd ~/migration
```

---

## 🧪 Passo 4: Testar Conectividade com os Clusters

No terminal do worker, valide se ambos os endpoints do Redis respondem ao `PING`:

### 4.1 Cluster sem TLS
```bash
redis-cli -h <ENDPOINT_ORIGEM> -p 6379 ping
redis-cli -h <ENDPOINT_DESTINO> -p 6379 ping
```
*(Deve responder `PONG`)*.

### 4.2 Cluster com Criptografia em Trânsito (TLS) e/ou Auth Token
```bash
redis-cli -h <ENDPOINT_ORIGEM> -p 6379 --tls -a '<SENHA_ORIGEM>' ping
redis-cli -h <ENDPOINT_DESTINO> -p 6379 --tls -a '<SENHA_DESTINO>' ping
```

---

## ⚡ Passo 5: Executar a Migração de Dados

> [!IMPORTANT]
> No AWS ElastiCache, comandos administrativos como `SYNC` ou `PSYNC` são bloqueados. Por isso, a migração com **RedisShake (Modo `scan`)** é a solução mais compatível e segura, pois lê chave a chave (`SCAN` + `DUMP`) e recria no destino (`RESTORE`) sem travar a origem.

### Opção A: Usando RedisShake (Já pré-instalado na EC2)

1. Crie o arquivo de configuração `shake.toml`:
```bash
cat << 'EOF' > shake.toml
[scan_reader]
# Endpoint da Origem (Conta A)
address = "<ENDPOINT_ORIGEM>:6379"
# username = ""
# password = "<SENHA_ORIGEM>"
# tls = false # Coloque true se o ElastiCache de origem usa criptografia em trânsito
# cluster = false # Coloque true se o modo de cluster estiver ativado

[redis_writer]
# Endpoint do Destino (Conta B)
address = "<ENDPOINT_DESTINO>:6379"
# username = ""
# password = "<SENHA_DESTINO>"
# tls = false # Coloque true se o ElastiCache de destino usa criptografia em trânsito
# cluster = false # Coloque true se o modo de cluster estiver ativado

[advanced]
dir = "data"
EOF
```

2. Execute o RedisShake dentro de uma sessão `tmux` (para não perder o progresso caso a sua conexão caia ou você feche o terminal):
```bash
# 1. Iniciar uma nova sessão chamada 'migracao':
tmux new -s migracao

# 2. Rodar a migração:
redis-shake shake.toml
```

#### 💡 Gerenciamento da Sessão do `tmux`:

* **Sair da sessão mantendo o processo em execução (Detach):**
  Pressione **`Ctrl + B`** (solte as teclas) e em seguida pressione **`D`**.
  *(A tela voltará para o prompt comum da EC2, mas a migração continuará rodando em segundo plano)*.

* **Listar sessões ativas do tmux:**
  ```bash
  tmux ls
  ```
  *(Exibe todas as sessões em execução no servidor e seu status)*.

* **Reconectar / Anexar na sessão (Attach):**
  ```bash
  # Reconectar na sessão específica:
  tmux attach -t migracao

  # Ou simplesmente reconectar na última sessão ativa:
  tmux a
  ```

* **Encerrar a sessão do tmux:**
  Quando a migração terminar e você quiser fechar o tmux, basta digitar `exit` dentro dele ou rodar:
  ```bash
  tmux kill-session -t migracao
  ```

---

### Opção B: Usando RIOT-X via Docker

O Docker já vem instalado e ativo no worker. Você pode rodar a replicação em um único comando:

```bash
docker run --rm -it --network host \
  redis/riotx \
  replicate \
  --source redis://<ENDPOINT_ORIGEM>:6379 \
  --target redis://<ENDPOINT_DESTINO>:6379
```

*Se houver senha e TLS (usar `rediss://` com dois 's'):*
```bash
docker run --rm -it --network host \
  redis/riotx \
  replicate \
  --source rediss://:<SENHA_ORIGEM>@<ENDPOINT_ORIGEM>:6379 \
  --target rediss://:<SENHA_DESTINO>@<ENDPOINT_DESTINO>:6379
```

---

## 🔍 Passo 6: Validar os Dados

Conecte-se em cada cluster e compare a contagem de chaves:

```bash
# Na Origem
redis-cli -h <ENDPOINT_ORIGEM> -p 6379 DBSIZE

# No Destino
redis-cli -h <ENDPOINT_DESTINO> -p 6379 DBSIZE
```

---

## 🧹 Passo 7: Limpeza Completa

Após concluir a validação e migração da aplicação para o novo cluster:

1. Saia da sessão da EC2:
```bash
exit
```

2. Destrua toda a infraestrutura temporária (EC2, VPC transitória, Peering e Rotas):
```powershell
terraform destroy -auto-approve
```

3. Remova a regra temporária de Inbound criada no Security Group dos ElastiCaches de Origem e Destino.