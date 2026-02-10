#!/bin/bash
# =============================================================================
# update-aws-credentials-github.sh
# =============================================================================
# Alternativa a update-aws-credentials.sh que usa GitHub Secrets en lloc
# d'AWS Secrets Manager.
#
# Actualitza les credencials AWS del Learner Lab:
#   1. Llegeix noves credencials de ~/.aws/credentials
#   2. Actualitza GitHub Secrets via `gh secret set`
#   3. Actualitza el K8s Secret directament (si te acces al cluster)
#      O dispara el workflow de GitHub Actions (si no te acces local)
#   4. Reinicia el controller EFS CSI
#
# Opcions:
#   --remote    Dispara el workflow de GitHub Actions en lloc d'aplicar localment
#
# Requereix:
#   - `gh` CLI autenticat (gh auth login)
#   - kubectl configurat (mode local) o GitHub Actions (mode --remote)
#
# Executar cada cop que es reinicia el Learner Lab.
#
# Us: ./scripts/update-aws-credentials-github.sh [--remote]
# =============================================================================
set -euo pipefail

NAMESPACE="kube-system"
SECRET_NAME="aws-credentials"
CREDENTIALS_FILE="${AWS_SHARED_CREDENTIALS_FILE:-$HOME/.aws/credentials}"
WORKFLOW_FILE="update-efs-credentials.yml"
MODE="local"

# Parsejar arguments
if [ "${1:-}" = "--remote" ]; then
  MODE="remote"
fi

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

# 2. Actualitzar GitHub Secrets
echo "==> [2/4] Actualitzant GitHub Secrets..."

echo "$KEY" | gh secret set AWS_ACCESS_KEY_ID
echo "$SECRET" | gh secret set AWS_SECRET_ACCESS_KEY
echo "$TOKEN" | gh secret set AWS_SESSION_TOKEN

echo "    OK (3 secrets actualitzats)"

if [ "$MODE" = "remote" ]; then
  # 3a. Disparar workflow de GitHub Actions
  echo "==> [3/4] Disparant workflow de GitHub Actions ($WORKFLOW_FILE)..."
  gh workflow run "$WORKFLOW_FILE"
  echo "    OK (workflow disparat)"

  # 4a. Esperar i mostrar estat
  echo "==> [4/4] Esperant execucio del workflow..."
  sleep 5
  gh run list --workflow="$WORKFLOW_FILE" --limit 1
  echo ""
  echo "==> Workflow disparat! Segueix l'execucio amb:"
  echo "  gh run list --workflow=$WORKFLOW_FILE"
  echo "  gh run watch"
else
  # 3b. Actualitzar K8s Secret directament
  echo "==> [3/4] Actualitzant K8s Secret directament..."

  kubectl create secret generic "$SECRET_NAME" \
    -n "$NAMESPACE" \
    --from-literal=AWS_ACCESS_KEY_ID="$KEY" \
    --from-literal=AWS_SECRET_ACCESS_KEY="$SECRET" \
    --from-literal=AWS_SESSION_TOKEN="$TOKEN" \
    --dry-run=client -o yaml | kubectl apply -f -
  echo "    OK"

  # 4b. Reiniciar controller
  echo "==> [4/4] Reiniciant efs-csi-controller per aplicar noves credencials"
  kubectl rollout restart deploy/efs-csi-controller -n "$NAMESPACE"
  kubectl rollout status deploy/efs-csi-controller -n "$NAMESPACE" --timeout=60s
fi

echo "==> Credencials actualitzades correctament!"
echo ""
echo "Verifica amb:"
echo "  gh secret list"
if [ "$MODE" = "local" ]; then
  echo "  kubectl exec deploy/efs-csi-controller -n kube-system -c efs-plugin -- env | grep AWS_"
fi
