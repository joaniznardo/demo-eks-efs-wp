#!/bin/bash
# =============================================================================
# setup-efs-dynamic.sh
# =============================================================================
# Configura el controller EFS CSI per usar provisionament dinamic a AWS Academy.
#
# Accions:
#   1. Elimina l'anotacio IRSA del Service Account (causa de l'error OIDC)
#   2. Crea el Secret amb les credencials AWS del Learner Lab
#   3. Patcheja el deployment del controller per injectar el Secret
#   4. Reinicia el controller
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

echo "============================================"
echo "  Setup EFS Dynamic Provisioning"
echo "  (AWS Academy / Learner Lab)"
echo "============================================"

# 1. Eliminar anotacio IRSA
echo ""
echo "==> [1/4] Eliminant anotacio IRSA del Service Account..."
kubectl annotate sa efs-csi-controller-sa -n "$NAMESPACE" \
  eks.amazonaws.com/role-arn- 2>/dev/null || true
echo "    OK"

# 2. Crear Secret amb credencials
echo ""
echo "==> [2/4] Creant Secret amb credencials AWS..."

KEY=$(sed -n 's/^aws_access_key_id=//p' "$CREDENTIALS_FILE" | head -1)
SECRET=$(sed -n 's/^aws_secret_access_key=//p' "$CREDENTIALS_FILE" | head -1)
TOKEN=$(sed -n 's/^aws_session_token=//p' "$CREDENTIALS_FILE" | head -1)

if [ -z "$KEY" ] || [ -z "$SECRET" ] || [ -z "$TOKEN" ]; then
  echo "ERROR: No s'han trobat credencials a $CREDENTIALS_FILE"
  exit 1
fi

kubectl create secret generic "$SECRET_NAME" \
  -n "$NAMESPACE" \
  --from-literal=AWS_ACCESS_KEY_ID="$KEY" \
  --from-literal=AWS_SECRET_ACCESS_KEY="$SECRET" \
  --from-literal=AWS_SESSION_TOKEN="$TOKEN" \
  --dry-run=client -o yaml | kubectl apply -f -
echo "    OK (KEY: ${KEY:0:12}...)"

# 3. Patchejar el deployment del controller
echo ""
echo "==> [3/4] Injectant credencials al efs-csi-controller..."

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

# 4. Esperar rollout
echo ""
echo "==> [4/4] Reiniciant controller..."
kubectl rollout status deploy/efs-csi-controller -n "$NAMESPACE" --timeout=90s

echo ""
echo "============================================"
echo "  Provisionament dinamic EFS configurat!"
echo "============================================"
echo ""
echo "Verifica amb:"
echo "  kubectl exec deploy/efs-csi-controller -n kube-system -c efs-plugin -- env | grep AWS_"
echo ""
echo "Quan el lab es reinicie, executa:"
echo "  ./scripts/update-aws-credentials.sh"
