#!/bin/bash
# =============================================================================
# setup-efs-github-secrets.sh
# =============================================================================
# Alternativa a setup-efs-dynamic.sh que usa GitHub Secrets en lloc
# d'AWS Secrets Manager per centralitzar les credencials.
#
# Accions:
#   1. Elimina l'anotacio IRSA del Service Account (causa de l'error OIDC)
#   2. Llegeix credencials de ~/.aws/credentials
#   3. Puja les credencials a GitHub Secrets via `gh secret set`
#   4. Crea el K8s Secret directament (GH Secrets son write-only)
#   5. Patcheja el deployment del controller per injectar el Secret
#   6. Reinicia el controller
#
# Requereix:
#   - `gh` CLI autenticat (gh auth login)
#   - Repositori GitHub configurat (git remote)
#   - kubectl configurat contra el cluster EKS
#
# Executar UNA SOLA VEGADA despres de crear el cluster EKS.
# Per actualitzar credencials despres, usar: update-aws-credentials-github.sh
#
# Us: ./scripts/setup-efs-github-secrets.sh
# =============================================================================
set -euo pipefail

NAMESPACE="kube-system"
SECRET_NAME="aws-credentials"
CREDENTIALS_FILE="${AWS_SHARED_CREDENTIALS_FILE:-$HOME/.aws/credentials}"

echo "============================================"
echo "  Setup EFS Dynamic Provisioning"
echo "  (GitHub Secrets + Acces local al cluster)"
echo "============================================"

# Verificar que gh CLI esta disponible i autenticat
if ! command -v gh &>/dev/null; then
  echo "ERROR: gh CLI no esta instal·lat. Instal·la'l des de https://cli.github.com/"
  exit 1
fi

if ! gh auth status &>/dev/null; then
  echo "ERROR: gh CLI no esta autenticat. Executa: gh auth login"
  exit 1
fi

# Verificar que estem en un repositori git amb remote
REPO=$(gh repo view --json nameWithOwner -q '.nameWithOwner' 2>/dev/null) || true
if [ -z "$REPO" ]; then
  echo "ERROR: No s'ha detectat cap repositori GitHub. Verifica que estas dins d'un repo git amb remote."
  exit 1
fi
echo "Repositori detectat: $REPO"

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

# 3. Pujar credencials a GitHub Secrets
echo ""
echo "==> [3/6] Pujant credencials a GitHub Secrets..."

echo "$KEY" | gh secret set AWS_ACCESS_KEY_ID
echo "$SECRET" | gh secret set AWS_SECRET_ACCESS_KEY
echo "$TOKEN" | gh secret set AWS_SESSION_TOKEN

echo "    OK (3 secrets pujats a $REPO)"

# 4. Crear K8s Secret directament (GH Secrets son write-only, no es poden llegir)
echo ""
echo "==> [4/6] Creant K8s Secret directament des de credencials locals..."

kubectl create secret generic "$SECRET_NAME" \
  -n "$NAMESPACE" \
  --from-literal=AWS_ACCESS_KEY_ID="$KEY" \
  --from-literal=AWS_SECRET_ACCESS_KEY="$SECRET" \
  --from-literal=AWS_SESSION_TOKEN="$TOKEN" \
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
echo "  (Credencials a GitHub Secrets + K8s)"
echo "============================================"
echo ""
echo "Verifica amb:"
echo "  kubectl exec deploy/efs-csi-controller -n kube-system -c efs-plugin -- env | grep AWS_"
echo ""
echo "GitHub Secrets:"
echo "  gh secret list"
echo ""
echo "Quan el lab es reinicie, executa:"
echo "  ./scripts/update-aws-credentials-github.sh"
