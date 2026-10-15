# Guia de Migração EFS Cross-Account com AWS DataSync Agent (Opção 2)

Este guia descreve o processo de migração de dados do diretório `/etc/seven` do EFS na **Conta A (Origem)** para o EFS na **Conta B (Destino)** utilizando o **AWS DataSync Agent** hospedado na VPC Transitória.

---

## 📌 Contexto da Arquitetura

* **Conta A (Origem)**:
  * Account ID: `352187878218` (Profile: `onnibank`)
  * EFS Mount Target IP na zona `sa-east-1a`: `10.100.14.7`
  * Diretório de leitura: `/etc/seven`
* **Conta B (Destino e Orquestradora)**:
  * Account ID: `741796255940` (Profile: `ringgo-prd`)
  * DataSync Agent: Instância EC2 na Subnet Transitória (`subnet-040ab98145c8bfa2e`)
  * EFS Destino: `fs-02b63fb6d41dd874f`
  * Location Destino já criada: `arn:aws:datasync:sa-east-1:741796255940:location/loc-0e467677eaa8747a6`

---

## 🚀 Passo 1: Aplicar o Terraform para subir o DataSync Agent

No terminal, execute o `terraform apply` para provisionar:
1. Internet Gateway e rota para saída à internet.
2. Atribuição de IP público na subnet transitória.
3. Security Group do Agent (portas 80, 443, 53 e 2049).
4. Instância EC2 do DataSync Agent (`ami-040cba75a89b7a1a2` - `m5.2xlarge`).

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

## 📍 Passo 3: Criar a Location NFS de Origem (Conta A via Agent)

Como o DataSync Agent está dentro da VPC Transitória conectada à Conta A via VPC Peering, o EFS da Conta A é acessado via NFS pelo IP do seu Mount Target:

```powershell
$SOURCE_LOC_ARN = (aws datasync create-location-nfs `
  --server-hostname "10.100.14.7" `
  --subdirectory "/etc/seven" `
  --on-prem-config "AgentArns=[$AGENT_ARN]" `
  --profile "ringgo-prd" `
  --query "LocationArn" --output text)

Write-Host "Source Location NFS criada: $SOURCE_LOC_ARN"
```

> [!NOTE]
> Esta localização lê diretamente os dados de `/etc/seven` do EFS da Conta A através do peering sem modificar nem criar arquivos na origem.

---

## 🎯 Passo 4: Criar a Tarefa (Task) no DataSync

A Location de destino já está provisionada na Conta B:
`arn:aws:datasync:sa-east-1:741796255940:location/loc-0e467677eaa8747a6`

Crie a tarefa vinculando a Origem NFS e o Destino EFS:

```powershell
$DEST_LOC_ARN = "arn:aws:datasync:sa-east-1:741796255940:location/loc-0e467677eaa8747a6"

$TASK_ARN = (aws datasync create-task `
  --source-location-arn $SOURCE_LOC_ARN `
  --destination-location-arn $DEST_LOC_ARN `
  --name "migracao-efs-seven" `
  --options 'VerifyMode=POINT_IN_TIME_CONSISTENT,Atime=BEST_EFFORT,Mtime=PRESERVE,Uid=INT_VALUE,Gid=INT_VALUE,PosixPermissions=PRESERVE' `
  --profile "ringgo-prd" `
  --query "TaskArn" --output text)

Write-Host "Task criada com sucesso: $TASK_ARN"
```

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

---

## 🧹 Passo 6: Limpeza após a Migração

Quando o status for `SUCCESS` e os dados estiverem validados no EFS de destino:

```powershell
# Destruir a infraestrutura transitória (EC2 Agent, Peering, Subnet e VPC)
terraform destroy -auto-approve
```