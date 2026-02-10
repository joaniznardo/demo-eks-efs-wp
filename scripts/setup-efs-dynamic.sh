#!/bin/bash
# =============================================================================
# setup-efs-dynamic.sh
# =============================================================================
# Configura el controller EFS CSI per usar provisionament dinamic a AWS Academy.
#
# Accions:
#   1. Elimina l'anotacio IRSA del Service Account (causa de l'error OIDC)
#   2. Llegeix credencials de ~/.aws/credentials
#   3. Crea/actualitza el secret a AWS Secrets Manager (centralitzacio)
#   4. Llegeix de Secrets Manager per crear el K8s Secret
#   5. Patcheja el deployment del controller per injectar el Secret
#   6. Reinicia el controller
#
# Executar UNA SOLA VEGADA despres de crear el cluster EKS.
# Per actualitzar credencials despres, usar: update-aws-credentials.sh
#
# Us: ./scripts/setup-efs-dynamic.sh
# =============================================================================
set -euo pipefail

NAMESPACE="kube-system"
SECRET_NAME="aws-credentials"
CREDENTIALS_FILE="${AWS_SHARED_CREDENTIALS_FILE:-$HOME/.aws/credentials}"
SM_SECRET_NAME="eks-efs-credentials"
SM_REGION="us-east-1"

echo "============================================"
echo "  Setup EFS Dynamic Provisioning"
echo "  (AWS Academy / Learner Lab)"
echo "============================================"

# 1. Eliminar anotacio IRSA
echo ""
echo "==> [1/6] Eliminant anotacio IRSA del Service Account..."
kubectl annotate sa efs-csi-controller-sa -n "$NAMESPACE" \
  eks.amazonaws.com/role-arn- 2>/dev/null || true
echo "    OK"

# 2. Llegir credencials locals
echo ""
echo "==> [2/6] Llegint credencials de $CREDENTIALS_FILE..."

KEY=$(sed -n 's/^aws_access_key_id=//p' "$CREDENTIALS_FILE" | head -1)
SECRET=$(sed -n 's/^aws_secret_access_key=//p' "$CREDENTIALS_FILE" | head -1)
TOKEN=$(sed -n 's/^aws_session_token=//p' "$CREDENTIALS_FILE" | head -1)

if [ -z "$KEY" ] || [ -z "$SECRET" ] || [ -z "$TOKEN" ]; then
  echo "ERROR: No s'han trobat credencials a $CREDENTIALS_FILE"
  exit 1
fi
echo "    OK (KEY: ${KEY:0:12}...)"

# 3. Crear/actualitzar secret a AWS Secrets Manager
echo ""
echo "==> [3/6] Creant/actualitzant secret a AWS Secrets Manager ($SM_SECRET_NAME)..."

SM_SECRET_VALUE=$(cat <<EOF
{"AWS_ACCESS_KEY_ID":"$KEY","AWS_SECRET_ACCESS_KEY":"$SECRET","AWS_SESSION_TOKEN":"$TOKEN"}
EOF
)

if aws secretsmanager describe-secret --secret-id "$SM_SECRET_NAME" --region "$SM_REGION" >/dev/null 2>&1; then
  aws secretsmanager update-secret \
    --secret-id "$SM_SECRET_NAME" \
    --secret-string "$SM_SECRET_VALUE" \
    --region "$SM_REGION" >/dev/null
  echo "    OK (actualitzat)"
else
  aws secretsmanager create-secret \
    --name "$SM_SECRET_NAME" \
    --description "Credencials AWS Learner Lab per EFS CSI Controller" \
    --secret-string "$SM_SECRET_VALUE" \
    --region "$SM_REGION" >/dev/null
  echo "    OK (creat)"
fi

# 4. Llegir de Secrets Manager per crear K8s Secret
echo ""
echo "==> [4/6] Llegint de Secrets Manager i creant K8s Secret..."

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

# 5. Patchejar el deployment del controller
echo ""
echo "==> [5/6] Injectant credencials al efs-csi-controller..."

# Obtenir el nombre de containers
NUM_CONTAINERS=$(kubectl get deploy efs-csi-controller -n "$NAMESPACE" \
  -o jsonpath='{.spec.template.spec.containers}' | python3 -c "import json,sys; print(len(json.load(sys.stdin)))")

PATCH="["
for i in $(seq 0 $((NUM_CONTAINERS - 1))); do
  [ "$i" -gt 0 ] && PATCH="$PATCH,"
  PATCH="$PATCH{\"op\":\"add\",\"path\":\"/spec/template/spec/containers/$i/envFrom\",\"value\":[{\"secretRef\":{\"name\":\"$SECRET_NAME\"}}]}"
done
PATCH="$PATCH]"

kubectl patch deploy efs-csi-controller -n "$NAMESPACE" --type=json -p="$PATCH"
echo "    OK ($NUM_CONTAINERS containers patchejats)"

# 6. Esperar rollout
echo ""
echo "==> [6/6] Reiniciant controller..."
kubectl rollout status deploy/efs-csi-controller -n "$NAMESPACE" --timeout=90s

echo ""
echo "============================================"
echo "  Provisionament dinamic EFS configurat!"
echo "============================================"
echo ""
echo "Verifica amb:"
echo "  kubectl exec deploy/efs-csi-controller -n kube-system -c efs-plugin -- env | grep AWS_"
echo ""
echo "Secret a AWS Secrets Manager:"
echo "  aws secretsmanager get-secret-value --secret-id $SM_SECRET_NAME --region $SM_REGION"
echo ""
echo "Quan el lab es reinicie, executa:"
echo "  ./scripts/update-aws-credentials.sh"
