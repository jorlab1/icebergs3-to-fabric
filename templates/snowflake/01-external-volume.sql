-- Replace all YOUR_* values; execute using an administrator-approved role.
CREATE EXTERNAL VOLUME FABRIC_POC_S3_VOL
  STORAGE_LOCATIONS = (
    (
      NAME = 'fabric-poc-s3'
      STORAGE_PROVIDER = 'S3'
      STORAGE_BASE_URL = 's3://YOUR_BUCKET/iceberg/'
      STORAGE_AWS_ROLE_ARN = 'arn:aws:iam::YOUR_AWS_ACCOUNT_ID:role/YOUR_WRITER_ROLE'
      STORAGE_AWS_EXTERNAL_ID = 'YOUR_EXTERNAL_ID'
    )
  )
  ALLOW_WRITES = TRUE;

DESC EXTERNAL VOLUME FABRIC_POC_S3_VOL;

-- Apply the final AWS trust using STORAGE_AWS_IAM_USER_ARN before this check.
SELECT SYSTEM$VERIFY_EXTERNAL_VOLUME('FABRIC_POC_S3_VOL');
