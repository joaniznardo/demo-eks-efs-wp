#!/bin/bash
# =============================================================================
# update-aws-credentials.sh
# =============================================================================
# Actualitza les credencials AWS del Learner Lab:
#   1. Llegeix noves credencials de ~/.aws/credentials
#   2. Actualitza el secret a AWS Secrets Manager
#   3. Llegeix de Secrets Manager per actualitzar el K8s Secret
#   4. Reinicia el controller EFS CSI
#
# Executar cada cop que es reinicia el Learner Lab.
#
# Us: ./scripts/update-aws-credentials.sh
# =============================================================================
set -euo pipefail

NAMESPACE="kube-system"
SECRET_NAME="aws-credentials"
CREDENTIALS_FILE="${AWS_SHARED_CREDENTIALS_FILE:-$HOME/.aws/credentials}"
SM_SECRET_NAME="eks-efs-credentials"
SM_REGION="us-east-1"

# 1. Llegir credencials locals
echo "==> [1/4] Llegint credencials de $CREDENTIALS_FILE"

KEY=$(sed -n 's/^aws_access_key_id=//p' "$CREDENTIALS_FILE" | head -1)
SECRET=$(sed -n 's/^aws_secret_access_key=//p' "$CREDENTIALS_FILE" | head -1)
TOKEN=$(sed -n 's/^aws_session_token=//p' "$CREDENTIALS_FILE" | head -1)

if [ -z "$KEY" ] || [ -z "$SECRET" ] || [ -z "$TOKEN" ]; then
  echo "ERROR: No s'han trobat credencials valides a $CREDENTIALS_FILE"
  exit 1
fi

echo "    AWS_ACCESS_KEY_ID: ${KEY:0:12}..."
echo "    AWS_SESSION_TOKEN: ${TOKEN:0:20}... (${#TOKEN} chars)"

# 2. Actualitzar secret a AWS Secrets Manager
echo "==> [2/4] Actualitzant secret a AWS Secrets Manager ($SM_SECRET_NAME)..."

SM_SECRET_VALUE=$(cat <<EOF
{"AWS_ACCESS_KEY_ID":"$KEY","AWS_SECRET_ACCESS_KEY":"$SECRET","AWS_SESSION_TOKEN":"$TOKEN"}
EOF
)

aws secretsmanager update-secret \
  --secret-id "$SM_SECRET_NAME" \
  --secret-string "$SM_SECRET_VALUE" \
  --region "$SM_REGION" >/dev/null
echo "    OK"

# 3. Llegir de Secrets Manager per actualitzar K8s Secret
echo "==> [3/4] Llegint de Secrets Manager i actualitzant K8s Secret..."

SM_VALUE=$(aws secretsmanager get-secret-value \
  --secret-id "$SM_SECRET_NAME" \
  --region "$SM_REGION" \
  --query 'SecretString' --output text)

SM_KEY=$(echo "$SM_VALUE" | python3 -c "import json,sys; print(json.load(sys.stdin)['AWS_ACCESS_KEY_ID'])")
SM_SECRET=$(echo "$SM_VALUE" | python3 -c "import json,sys; print(json.load(sys.stdin)['AWS_SECRET_ACCESS_KEY'])")
SM_TOKEN=$(echo "$SM_VALUE" | python3 -c "import json,sys; print(json.load(sys.stdin)['AWS_SESSION_TOKEN'])")

kubectl create secret generic "$SECRET_NAME" \
  -n "$NAMESPACE" \
  --from-literal=AWS_ACCESS_KEY_ID="$SM_KEY" \
  --from-literal=AWS_SECRET_ACCESS_KEY="$SM_SECRET" \
  --from-literal=AWS_SESSION_TOKEN="$SM_TOKEN" \
  --dry-run=client -o yaml | kubectl apply -f -
echo "    OK"

# 4. Reiniciar controller
echo "==> [4/4] Reiniciant efs-csi-controller per aplicar noves credencials"
kubectl rollout restart deploy/efs-csi-controller -n "$NAMESPACE"
kubectl rollout status deploy/efs-csi-controller -n "$NAMESPACE" --timeout=60s

echo "==> Credencials actualitzades correctament!"
echo ""
echo "Verifica amb:"
echo "  aws secretsmanager get-secret-value --secret-id $SM_SECRET_NAME --region $SM_REGION"
echo "  kubectl exec deploy/efs-csi-controller -n kube-system -c efs-plugin -- env | grep AWS_"
