# Guia de Migração EFS Cross-Account com AWS DataSync Agent (Opção 2)

Este guia descreve o processo de migração de diretórios (como `/etc/seven`, `/var/log/seven` e `/opt/seven`) do EFS na **Conta A (Origem)** para o EFS na **Conta B (Destino)** utilizando o **AWS DataSync Agent** hospedado na VPC Transitória.

---

## 📌 Contexto da Arquitetura

* **Conta A (Origem)**:
  * Account ID: `352187878218` (Profile: `onnibank`)
  * EFS Mount Target IP na zona `sa-east-1a`: `10.100.14.7`
  * Route Table da subnet do EFS: `rtb-0a29b4cc7c7f0230f` (Private subnet 1A)
* **Conta B (Destino e Orquestradora)**:
  * Account ID: `741796255940` (Profile: `ringgo-prd`)
  * DataSync Agent: Instância EC2 na Subnet Transitória (`subnet-040ab98145c8bfa2e`)
  * EFS Destino: `fs-02b63fb6d41dd874f` (Mount Target `sa-east-1a`: `10.100.11.14`)
  * Bastion Host: `ringgo-bastion` (`i-0567946890bf87148`)
  * Subnet do EFS Destino: `subnet-0f9213d437b5254f3`
  * Security Group do EFS Destino: `sg-07980ae22025ab5dc`

---

## 🚀 Passo 1: Aplicar o Terraform para subir o DataSync Agent

No terminal, execute o `terraform apply` para provisionar:
1. Internet Gateway e rota para saída à internet.
2. Atribuição de IP público na subnet transitória.
3. Security Group do Agent (portas 80, 443, 53 e 2049).
4. Instância EC2 do DataSync Agent (`ami-040cba75a89b7a1a2` - `m5.2xlarge`).
5. VPC Peering e rotas entre a VPC Transitória e as VPCs das duas contas.

```powershell
terraform apply -auto-approve
```

Ao final, observe os outputs com o IP público e URL de ativação do Agent:
```text
datasync_agent_public_ip = "x.x.x.x"
datasync_agent_activation_url = "http://x.x.x.x/?gatewayType=SYNC&activationRegion=sa-east-1&endpointType=PUBLIC"
```

---

## 🔑 Passo 2: Obter a ActivationKey e Ativar o Agent

Aguarde cerca de 1 a 2 minutos após o boot da EC2 para o serviço web do DataSync iniciar.

### 2.1 Obter a ActivationKey (PowerShell)
```powershell
$AGENT_IP = (terraform output -raw datasync_agent_public_ip)
$ACTIVATION_KEY = (Invoke-RestMethod -Uri "http://${AGENT_IP}/?gatewayType=SYNC&activationRegion=sa-east-1&no_redirect")
Write-Host "Activation Key: $ACTIVATION_KEY"
```

### 2.2 Registrar o Agent no DataSync (Conta B)
```powershell
$AGENT_ARN = (aws datasync create-agent `
  --agent-name "datasync-agent-efs" `
  --activation-key $ACTIVATION_KEY `
  --profile "ringgo-prd" `
  --query "AgentArn" --output text)

Write-Host "Agent criado: $AGENT_ARN"
```

---

## 📁 Passo 3: Pré-requisito no Destino (Criar Diretórios no EFS via Bastion)

> [!IMPORTANT]
> O Amazon EFS **não cria subdiretórios automaticamente** quando montado via DataSync. Se você apontar uma Location para `/var/log/seven` ou `/opt/seven` sem que ela exista fisicamente no disco do EFS de destino, a tarefa falhará com erro `Could not mount subdirectory`.

### 3.1 Conectar no Bastion via Session Manager
No seu terminal PowerShell:
```powershell
aws ssm start-session --target "i-0567946890bf87148" --profile "ringgo-prd" --region "sa-east-1"
```

### 3.2 Montar o EFS e criar as pastas de destino
Dentro da sessão do Linux no bastion:
```bash
sudo su -

# 1. Montar a raiz do EFS no bastion
mkdir -p /mnt/efs
mount -t nfs4 -o nfsvers=4.1 10.100.11.14:/ /mnt/efs

# 2. Criar as estruturas de diretórios desejadas
# Para /etc/seven:
mkdir -p /mnt/efs/etc/seven
chmod -R 755 /mnt/efs/etc

# Para /var/log/seven:
mkdir -p /mnt/efs/var/log/seven
chmod -R 755 /mnt/efs/var
chown -R 1000:1000 /mnt/efs/var/log/seven

# Para /opt/seven:
mkdir -p /mnt/efs/opt/seven
chmod -R 755 /mnt/efs/opt

# 3. Conferir a criação
ls -la /mnt/efs/

# 4. Desmontar o EFS e sair
umount /mnt/efs
exit
exit
```

---

## 📍 Passo 4: Criar as Locations e Tasks no DataSync

Você pode criar uma tarefa para cada diretório que deseja sincronizar, reutilizando o mesmo Agent e as mesmas subnets.

### Exemplo: Migração de `/var/log/seven`

#### 4.1 Criar Location de Origem (Conta A)
```powershell
$AGENT_ARN = "arn:aws:datasync:sa-east-1:741796255940:agent/agent-0c8fab9210bfb5789"

$SRC_LOC = (aws datasync create-location-nfs `
  --server-hostname "10.100.14.7" `
  --subdirectory "/var/log/seven" `
  --on-prem-config "AgentArns=[$AGENT_ARN]" `
  --profile "ringgo-prd" `
  --query "LocationArn" --output text)

Write-Host "Origem criada: $SRC_LOC"
```

#### 4.2 Criar Location de Destino (Conta B)
```powershell
$DST_LOC = (aws datasync create-location-efs `
  --efs-filesystem-arn "arn:aws:elasticfilesystem:sa-east-1:741796255940:file-system/fs-02b63fb6d41dd874f" `
  --subdirectory "/var/log/seven" `
  --ec2-config "SubnetArn=arn:aws:ec2:sa-east-1:741796255940:subnet/subnet-0f9213d437b5254f3,SecurityGroupArns=[arn:aws:ec2:sa-east-1:741796255940:security-group/sg-07980ae22025ab5dc]" `
  --profile "ringgo-prd" `
  --query "LocationArn" --output text)

Write-Host "Destino criado: $DST_LOC"
```

#### 4.3 Criar a Tarefa (Task)
```powershell
$TASK_ARN = (aws datasync create-task `
  --source-location-arn $SRC_LOC `
  --destination-location-arn $DST_LOC `
  --name "migracao-efs-var-log-seven" `
  --options "VerifyMode=POINT_IN_TIME_CONSISTENT,Atime=BEST_EFFORT,Mtime=PRESERVE,Uid=INT_VALUE,Gid=INT_VALUE,PosixPermissions=PRESERVE" `
  --profile "ringgo-prd" `
  --query "TaskArn" --output text)

Write-Host "Task criada: $TASK_ARN"
```

*(Para migrar `/opt/seven`, repita o processo acima alterando apenas o `--subdirectory` para `/opt/seven` e o `--name` para `migracao-efs-opt-seven`).*

---

## ⚡ Passo 5: Executar a Migração e Acompanhar

### 5.1 Iniciar a Execução
```powershell
$EXECUTION_ARN = (aws datasync start-task-execution `
  --task-arn $TASK_ARN `
  --profile "ringgo-prd" `
  --query "TaskExecutionArn" --output text)

Write-Host "Execução iniciada: $EXECUTION_ARN"
```

### 5.2 Monitorar o Status
```powershell
aws datasync describe-task-execution `
  --task-execution-arn $EXECUTION_ARN `
  --profile "ringgo-prd" `
  --query "Status"
```
*(Os status evoluem de `LAUNCHING` -> `PREPARING` -> `TRANSFERRING` -> `VERIFYING` -> `SUCCESS`)*.

### 5.3 Validar os Arquivos pelo Bastion
Conecte-se no bastion e valide os arquivos transferidos:
```bash
sudo mkdir -p /mnt/efs
sudo mount -t nfs4 -o nfsvers=4.1 10.100.11.14:/ /mnt/efs

# Listar os arquivos transferidos
ls -lhR /mnt/efs/var/log/seven/

# Contar arquivos
find /mnt/efs/var/log/seven -type f | wc -l

sudo umount /mnt/efs
```

---

## 🧹 Passo 6: Limpeza Completa após Concluir Todas as Migrações

Quando todas as tarefas forem concluídas com `SUCCESS` e os dados estiverem validados:

### 6.1 Deletar os Recursos do DataSync (Conta B)
```powershell
# Deletar as tarefas (ajuste com os ARNs das tarefas criadas)
aws datasync delete-task --task-arn "<TASK_ARN>" --profile "ringgo-prd"

# Deletar as locations NFS e EFS
aws datasync delete-location --location-arn "<SOURCE_LOCATION_ARN>" --profile "ringgo-prd"
aws datasync delete-location --location-arn "<DEST_LOCATION_ARN>" --profile "ringgo-prd"

# Deletar o Agent
aws datasync delete-agent --agent-arn "<AGENT_ARN>" --profile "ringgo-prd"
```

### 6.2 Remover a Rota de Retorno Manual na Conta A
```powershell
aws ec2 delete-route `
  --route-table-id "rtb-0a29b4cc7c7f0230f" `
  --destination-cidr-block "172.31.0.0/24" `
  --profile "onnibank" `
  --region "sa-east-1"
```

### 6.3 Reverter Regras de Security Group (Opcional)

#### Conta A (remover liberação temporária da porta 2049):
```powershell
aws ec2 revoke-security-group-ingress `
  --group-id "sg-079671cae139b4247" `
  --security-group-rule-ids "sgr-02868ed30410dc7f1" `
  --profile "onnibank" `
  --region "sa-east-1"
```

#### Conta B (remover regras adicionadas em `onnibank-prd-efs-sg`):
```powershell
# Remover saída (egress)
aws ec2 revoke-security-group-egress `
  --group-id "sg-07980ae22025ab5dc" `
  --security-group-rule-ids "sgr-06d27efdbc9d36bfd" `
  --profile "ringgo-prd" `
  --region "sa-east-1"

# Remover auto-referência ingress 2049
aws ec2 revoke-security-group-ingress `
  --group-id "sg-07980ae22025ab5dc" `
  --security-group-rule-ids "sgr-0748219a4f706b3cc" `
  --profile "ringgo-prd" `
  --region "sa-east-1"
```

### 6.4 Destruir a Infraestrutura Transitória (Terraform)
```powershell
terraform destroy -auto-approve
```