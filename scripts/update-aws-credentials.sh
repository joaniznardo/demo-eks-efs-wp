#!/bin/bash
# =============================================================================
# update-aws-credentials.sh
# =============================================================================
# Actualitza les credencials AWS del Learner Lab al Secret de Kubernetes
# que usa el controller EFS CSI per al provisionament dinamic.
#
# Executar cada cop que es reinicia el Learner Lab.
#
# Us: ./scripts/update-aws-credentials.sh
# =============================================================================
set -euo pipefail

NAMESPACE="kube-system"
SECRET_NAME="aws-credentials"
CREDENTIALS_FILE="${AWS_SHARED_CREDENTIALS_FILE:-$HOME/.aws/credentials}"

echo "==> Llegint credencials de $CREDENTIALS_FILE"

KEY=$(sed -n 's/^aws_access_key_id=//p' "$CREDENTIALS_FILE" | head -1)
SECRET=$(sed -n 's/^aws_secret_access_key=//p' "$CREDENTIALS_FILE" | head -1)
TOKEN=$(sed -n 's/^aws_session_token=//p' "$CREDENTIALS_FILE" | head -1)

if [ -z "$KEY" ] || [ -z "$SECRET" ] || [ -z "$TOKEN" ]; then
  echo "ERROR: No s'han trobat credencials valides a $CREDENTIALS_FILE"
  exit 1
fi

echo "==> AWS_ACCESS_KEY_ID: ${KEY:0:12}..."
echo "==> AWS_SESSION_TOKEN: ${TOKEN:0:20}... (${#TOKEN} chars)"

echo "==> Actualitzant Secret $SECRET_NAME a $NAMESPACE"

kubectl create secret generic "$SECRET_NAME" \
  -n "$NAMESPACE" \
  --from-literal=AWS_ACCESS_KEY_ID="$KEY" \
  --from-literal=AWS_SECRET_ACCESS_KEY="$SECRET" \
  --from-literal=AWS_SESSION_TOKEN="$TOKEN" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "==> Reiniciant efs-csi-controller per aplicar noves credencials"
kubectl rollout restart deploy/efs-csi-controller -n "$NAMESPACE"
kubectl rollout status deploy/efs-csi-controller -n "$NAMESPACE" --timeout=60s

echo "==> Credencials actualitzades correctament!"
