$BUCKET_NAME = "e-consig-prod"
$ROLE_ARN = "arn:aws:iam::741796255940:role/DataSyncS3CrossAccountRole"

aws s3api create-bucket `
    --bucket "ringgo-$BUCKET_NAME" `
    --region "sa-east-1" `
    --create-bucket-configuration LocationConstraint="sa-east-1" `
    --profile "ringgo-prd"

# 4.1 Criar Location S3 de Origem (Conta A)
$SRC_LOC = (aws datasync create-location-s3 `
        --s3-bucket-arn "arn:aws:s3:::$BUCKET_NAME" `
        --s3-config "BucketAccessRoleArn=$ROLE_ARN" `
        --s3-storage-class "STANDARD" `
        --profile "ringgo-prd" `
        --region "sa-east-1" `
        --query "LocationArn" --output text)

Write-Host "Location Origem criada: $SRC_LOC"

# 4.2 Criar Location S3 de Destino (Conta B)
$DST_LOC = (aws datasync create-location-s3 `
        --s3-bucket-arn "arn:aws:s3:::ringgo-$BUCKET_NAME" `
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
        --name "migracao-s3-$BUCKET_NAME" `
        --options "VerifyMode=POINT_IN_TIME_CONSISTENT,Atime=BEST_EFFORT,Mtime=PRESERVE,OverwriteMode=ALWAYS,TransferMode=CHANGED,ObjectTags=PRESERVE" `
        --profile "ringgo-prd" `
        --region "sa-east-1" `
        --query "TaskArn" --output text)

Write-Host "Task criada com sucesso: $TASK_ARN"