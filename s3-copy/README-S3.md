# Guia de Migração S3 Cross-Account com AWS DataSync (Serverless)

Este guia descreve o processo de migração de buckets S3 da **Conta A (Origem - `onnibank`)** para a **Conta B (Destino - `ringgo-prd`)** utilizando o **AWS DataSync** de forma **Serverless** (sem necessidade de EC2, VPC transitória ou VPC Peering).

---

## 📌 Contexto da Arquitetura

* **Conta A (Origem)**:
  * Account ID: `352187878218` (Profile: `onnibank`)
  * Bucket de Origem: `btg-iron-mt` (exemplo)
  * Região: `sa-east-1`
* **Conta B (Destino e Orquestradora)**:
  * Account ID: `741796255940` (Profile: `ringgo-prd`)
  * Bucket de Destino: `ringgo-btg-iron-mt`
  * Região: `sa-east-1`
  * IAM Role: `DataSyncS3CrossAccountRole`

---

## 🪣 Passo 1: Criar o Bucket de Destino (Conta B)

No PowerShell, crie o bucket na Conta B:

```powershell
aws s3api create-bucket `
  --bucket "ringgo-btg-iron-mt" `
  --region "sa-east-1" `
  --create-bucket-configuration LocationConstraint="sa-east-1" `
  --profile "ringgo-prd"
```

> [!NOTE]
> Por padrão, o bucket criado já habilita criptografia SSE-S3 e **Bucket Owner Enforced**, garantindo que a Conta B seja proprietária de 100% dos objetos migrados.

---

## 🔑 Passo 2: Criar a IAM Role do DataSync (Conta B)

O DataSync precisa de uma IAM Role para autenticar e executar a cópia entre os buckets:

```powershell
# 2.1 Definir a Trust Policy (permite que o DataSync assuma a Role)
$TRUST_POLICY = @'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": { "Service": "datasync.amazonaws.com" },
      "Action": "sts:AssumeRole",
      "Condition": {
        "StringEquals": { "aws:SourceAccount": "741796255940" }
      }
    }
  ]
}
'@

# 2.2 Criar a Role
aws iam create-role `
  --role-name "DataSyncS3CrossAccountRole" `
  --assume-role-policy-document $TRUST_POLICY `
  --description "Role para migracao S3 cross-account via DataSync" `
  --profile "ringgo-prd"

# 2.3 Definir as Permissões (Leitura na Conta A e Gravação na Conta B)
$PERM_POLICY = @'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "LeituraOrigemContaA",
      "Effect": "Allow",
      "Action": [
        "s3:GetBucketLocation",
        "s3:ListBucket",
        "s3:ListBucketMultipartUploads",
        "s3:GetObject",
        "s3:GetObjectTagging",
        "s3:GetObjectVersion",
        "s3:GetObjectVersionTagging"
      ],
      "Resource": [
        "arn:aws:s3:::*",
        "arn:aws:s3:::*/*"
      ]
    },
    {
      "Sid": "EscritaDestinoContaB",
      "Effect": "Allow",
      "Action": [
        "s3:GetBucketLocation",
        "s3:ListBucket",
        "s3:ListBucketMultipartUploads",
        "s3:AbortMultipartUpload",
        "s3:DeleteObject",
        "s3:GetObject",
        "s3:GetObjectTagging",
        "s3:PutObject",
        "s3:PutObjectTagging"
      ],
      "Resource": [
        "arn:aws:s3:::*",
        "arn:aws:s3:::*/*"
      ]
    }
  ]
}
'@

# 2.4 Anexar a Política à Role
aws iam put-role-policy `
  --role-name "DataSyncS3CrossAccountRole" `
  --policy-name "DataSyncS3Policy" `
  --policy-document $PERM_POLICY `
  --profile "ringgo-prd"

Write-Host "IAM Role criada com sucesso na Conta B!"
```

---

## 🛡️ Passo 3: Atualizar a Bucket Policy no Bucket de Origem (Conta A)

No bucket **`btg-iron-mt`** na Conta A, aplique a política que autoriza a Role da Conta B a ler os arquivos (preservando as regras existentes de SSL, CloudTrail e Logging):

```powershell
$BUCKET_POLICY = @'
{
    "Version": "2012-10-17",
    "Id": "btg-iron-mt-policy",
    "Statement": [
        {
            "Sid": "AllowSSLRequestsOnly",
            "Effect": "Deny",
            "Principal": "*",
            "Action": "s3:*",
            "Resource": [
                "arn:aws:s3:::btg-iron-mt",
                "arn:aws:s3:::btg-iron-mt/*"
            ],
            "Condition": {
                "Bool": {
                    "aws:SecureTransport": "false"
                }
            }
        },
        {
            "Sid": "AllowS3ServerLogging",
            "Effect": "Allow",
            "Principal": {
                "Service": "logging.s3.amazonaws.com"
            },
            "Action": "s3:PutObject",
            "Resource": "arn:aws:s3:::btg-iron-mt/*",
            "Condition": {
                "StringEquals": {
                    "aws:SourceAccount": "352187878218"
                }
            }
        },
        {
            "Sid": "AllowCloudTrailBucketAclCheck",
            "Effect": "Allow",
            "Principal": {
                "Service": "cloudtrail.amazonaws.com"
            },
            "Action": "s3:GetBucketAcl",
            "Resource": "arn:aws:s3:::btg-iron-mt",
            "Condition": {
                "StringEquals": {
                    "aws:SourceAccount": "352187878218"
                }
            }
        },
        {
            "Sid": "AllowCloudTrailToPutLogs",
            "Effect": "Allow",
            "Principal": {
                "Service": "cloudtrail.amazonaws.com"
            },
            "Action": "s3:PutObject",
            "Resource": "arn:aws:s3:::btg-iron-mt/AWSLogs/352187878218/*",
            "Condition": {
                "StringEquals": {
                    "aws:SourceArn": "arn:aws:cloudtrail:sa-east-1:352187878218:trail/btg-iron-trail",
                    "aws:SourceAccount": "352187878218"
                }
            }
        },
        {
            "Sid": "AllowDataSyncCrossAccountRead",
            "Effect": "Allow",
            "Principal": {
                "AWS": "arn:aws:iam::741796255940:role/DataSyncS3CrossAccountRole"
            },
            "Action": [
                "s3:GetBucketLocation",
                "s3:ListBucket",
                "s3:ListBucketMultipartUploads",
                "s3:GetObject",
                "s3:GetObjectTagging",
                "s3:GetObjectVersion",
                "s3:GetObjectVersionTagging"
            ],
            "Resource": [
                "arn:aws:s3:::btg-iron-mt",
                "arn:aws:s3:::btg-iron-mt/*"
            ]
        }
    ]
}
'@

aws s3api put-bucket-policy `
  --bucket "btg-iron-mt" `
  --policy $BUCKET_POLICY `
  --profile "onnibank"

Write-Host "Bucket Policy atualizada com sucesso no bucket btg-iron-mt!"
```

---

## 📍 Passo 4: Criar as Locations e a Task no DataSync (Conta B)

Com as permissões configuradas em ambas as pontas, crie as Locations S3 e a Task na Conta B:

```powershell
$ROLE_ARN = "arn:aws:iam::741796255940:role/DataSyncS3CrossAccountRole"

# 4.1 Criar Location S3 de Origem (Conta A)
$SRC_LOC = (aws datasync create-location-s3 `
  --s3-bucket-arn "arn:aws:s3:::btg-iron-mt" `
  --s3-config "BucketAccessRoleArn=$ROLE_ARN" `
  --s3-storage-class "STANDARD" `
  --profile "ringgo-prd" `
  --region "sa-east-1" `
  --query "LocationArn" --output text)

Write-Host "Location Origem criada: $SRC_LOC"

# 4.2 Criar Location S3 de Destino (Conta B)
$DST_LOC = (aws datasync create-location-s3 `
  --s3-bucket-arn "arn:aws:s3:::ringgo-btg-iron-mt" `
  --s3-config "BucketAccessRoleArn=$ROLE_ARN" `
  --s3-storage-class "STANDARD" `
  --profile "ringgo-prd" `
  --region "sa-east-1" `
  --query "LocationArn" --output text)

Write-Host "Location Destino criada: $DST_LOC"

# 4.3 Criar a Task vinculando Origem e Destino
$TASK_ARN = (aws datasync create-task `
  --source-location-arn $SRC_LOC `
  --destination-location-arn $DST_LOC `
  --name "migracao-s3-btg-iron-mt" `
  --options "VerifyMode=POINT_IN_TIME_CONSISTENT,Atime=BEST_EFFORT,Mtime=PRESERVE,OverwriteMode=ALWAYS,TransferMode=CHANGED,ObjectTags=PRESERVE" `
  --profile "ringgo-prd" `
  --region "sa-east-1" `
  --query "TaskArn" --output text)

Write-Host "Task criada com sucesso: $TASK_ARN"
```

---

## ⚡ Passo 5: Executar a Migração e Acompanhar

### 5.1 Iniciar a Execução
```powershell
$EXEC_ARN = (aws datasync start-task-execution `
  --task-arn $TASK_ARN `
  --profile "ringgo-prd" `
  --region "sa-east-1" `
  --query "TaskExecutionArn" --output text)

Write-Host "Execução iniciada: $EXEC_ARN"
```

### 5.2 Monitorar o Status
```powershell
aws datasync describe-task-execution `
  --task-execution-arn $EXEC_ARN `
  --profile "ringgo-prd" `
  --region "sa-east-1" `
  --query "Status"
```
*(Status: `LAUNCHING` -> `PREPARING` -> `TRANSFERRING` -> `VERIFYING` -> `SUCCESS`)*.

---

## 🔄 Passo 6: Virada de Chave (Cutover)

Como a tarefa usa `TransferMode=CHANGED`:
1. Você pode rodar a carga inicial dias antes da virada de chave.
2. Na janela de corte da aplicação, basta rodar o comando do **Passo 5.1** novamente: o DataSync varrerá o bucket e sincronizará em poucos minutos apenas os arquivos criados ou alterados recentemente.
3. Atualize a variável de ambiente da aplicação apontando para `ringgo-btg-iron-mt`.

---

## 🧹 Passo 7: Limpeza Pós-Migração (Opcional)

Após validar a aplicação rodando com sucesso no novo bucket:

```powershell
# Deletar a Task
aws datasync delete-task --task-arn $TASK_ARN --profile "ringgo-prd" --region "sa-east-1"

# Deletar as Locations
aws datasync delete-location --location-arn $SRC_LOC --profile "ringgo-prd" --region "sa-east-1"
aws datasync delete-location --location-arn $DST_LOC --profile "ringgo-prd" --region "sa-east-1"

# (Opcional) Remover o bloco AllowDataSyncCrossAccountRead da Bucket Policy na Conta A
```
