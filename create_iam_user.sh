#!/usr/bin/env bash
set -euo pipefail

USERNAME="smohan_neon_access"
REGION="us-west-2"

echo "=== Creating IAM user: ${USERNAME} ==="
aws iam create-user --user-name "${USERNAME}" 2>/dev/null \
    && echo "  User created." \
    || echo "  User already exists — skipping creation."

echo ""
echo "=== Attaching AdministratorAccess ==="
echo "  (eksctl needs broad permissions: EKS, EC2, CloudFormation, IAM, VPC, ASG, ELB, SSM, etc.)"
aws iam attach-user-policy \
    --user-name "${USERNAME}" \
    --policy-arn "arn:aws:iam::aws:policy/AdministratorAccess"
echo "  Done."

echo ""
echo "=== Creating access keys ==="
ACCESS_KEY_OUTPUT=$(aws iam create-access-key --user-name "${USERNAME}" --output json)

ACCESS_KEY_ID=$(echo "${ACCESS_KEY_OUTPUT}" | jq -r '.AccessKey.AccessKeyId')
SECRET_KEY=$(echo "${ACCESS_KEY_OUTPUT}" | jq -r '.AccessKey.SecretAccessKey')

echo ""
echo "=========================================="
echo " IAM User Created Successfully"
echo "=========================================="
echo " Username:        ${USERNAME}"
echo " Access Key ID:   ${ACCESS_KEY_ID}"
echo " Secret Key:      ${SECRET_KEY}"
echo " Region:          ${REGION}"
echo "=========================================="
echo ""
echo " SAVE THESE CREDENTIALS NOW -- the secret key cannot be retrieved again."
echo ""
echo " Export for use with setup scripts:"
echo "   export AWS_ACCESS_KEY_ID=${ACCESS_KEY_ID}"
echo "   export AWS_SECRET_ACCESS_KEY=${SECRET_KEY}"
echo "   export AWS_DEFAULT_REGION=${REGION}"
echo ""
echo " To tear down this user later:"
echo "   aws iam detach-user-policy --user-name ${USERNAME} --policy-arn arn:aws:iam::aws:policy/AdministratorAccess"
echo "   aws iam delete-access-key --user-name ${USERNAME} --access-key-id ${ACCESS_KEY_ID}"
echo "   aws iam delete-user --user-name ${USERNAME}"
echo ""
