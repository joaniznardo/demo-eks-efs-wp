# Provisionament Dinamic EFS a AWS Academy

## El problema: OIDC absent

El driver EFS CSI utilitza **IRSA** (IAM Roles for Service Accounts) per autenticar-se
contra l'API d'AWS i crear Access Points dinamicament. IRSA requereix un **OIDC Identity
Provider** registrat al compte AWS.

```
PVC (Pending) → CSI Controller → IRSA → OIDC Provider → ❌ No existeix!
```

**AWS Academy no te OIDC provider** i el permis `iam:CreateOpenIDConnectProvider` no esta
disponible amb LabRole. Sense OIDC, el controller rep:

```
InvalidIdentityToken: No OpenIDConnect provider found in your account for
https://oidc.eks.us-east-1.amazonaws.com/id/XXXXXXXXX
```

## Per que EBS si funciona i EFS no?

El driver **EBS CSI** funciona a AWS Academy perque utilitza una **cadena de resolucio
de credencials** diferent. Quan EBS CSI no pot usar IRSA, cau a l'**EC2 Instance Metadata
Service (IMDS)**, que proporciona credencials temporals del rol associat a la instancia EC2
(en el cas d'AWS Academy, LabRole).

El driver **EFS CSI** tambe intenta usar IMDS com a fallback, pero falla perque:

1. El pod del controller te una anotacio IRSA al Service Account:
   ```
   eks.amazonaws.com/role-arn: arn:aws:iam::XXXX:role/...
   ```
2. Amb aquesta anotacio, el SDK d'AWS intenta usar el **web identity token** (IRSA)
   abans de caure a IMDS
3. El token IRSA falla (no hi ha OIDC) i el SDK **no continua** amb la cadena de fallback
   perque interpreta l'error OIDC com un error d'autenticacio definitiu

## La solucio: injectar credencials com a variables d'entorn

La cadena de resolucio de credencials de l'**AWS SDK v2** te aquest ordre de prioritat:

```
1. Variables d'entorn (AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY, AWS_SESSION_TOKEN)
2. Fitxer de credencials (~/.aws/credentials)
3. Web Identity Token (IRSA)
4. EC2 Instance Metadata Service (IMDS)
```

Les **variables d'entorn tenen la maxima prioritat**. Si injectem les credencials del
Learner Lab com a variables d'entorn als containers del controller EFS CSI, el SDK les
usara directament sense intentar IRSA ni IMDS.

## AWS Secrets Manager com a capa de centralitzacio

Les credencials es gestionen a traves d'**AWS Secrets Manager** com a punt central
d'emmagatzematge. Aixo permet:

- **Centralitzacio**: un unic punt de veritat per les credencials
- **Comparticio entre equips**: multiples desenvolupadors poden llegir el secret sense accedir al fitxer local d'un altre
- **Auditoria**: AWS CloudTrail registra cada acces al secret
- **Integracio**: altres serveis AWS poden llegir les credencials directament de Secrets Manager

### Flux de credencials

```
~/.aws/credentials → AWS Secrets Manager → K8s Secret → EFS CSI Controller
```

1. Les credencials es llegeixen del fitxer local `~/.aws/credentials`
2. Es pugen a AWS Secrets Manager amb el nom `eks-efs-credentials`
3. Es llegeixen de Secrets Manager per crear el K8s Secret `aws-credentials`
4. El K8s Secret s'injecta com a variables d'entorn al controller

### Comandes AWS CLI per Secrets Manager

```bash
# Crear el secret (primera vegada)
aws secretsmanager create-secret \
  --name eks-efs-credentials \
  --description "Credencials AWS Learner Lab per EFS CSI Controller" \
  --secret-string '{"AWS_ACCESS_KEY_ID":"...","AWS_SECRET_ACCESS_KEY":"...","AWS_SESSION_TOKEN":"..."}' \
  --region us-east-1

# Actualitzar el secret (cada reinici del lab)
aws secretsmanager update-secret \
  --secret-id eks-efs-credentials \
  --secret-string '{"AWS_ACCESS_KEY_ID":"...","AWS_SECRET_ACCESS_KEY":"...","AWS_SESSION_TOKEN":"..."}' \
  --region us-east-1

# Llegir el secret
aws secretsmanager get-secret-value \
  --secret-id eks-efs-credentials \
  --region us-east-1

# Eliminar el secret (neteja)
aws secretsmanager delete-secret \
  --secret-id eks-efs-credentials \
  --force-delete-without-recovery \
  --region us-east-1
```

### Passos

#### 1. Eliminar l'anotacio IRSA del Service Account

```bash
kubectl annotate sa efs-csi-controller-sa -n kube-system \
  eks.amazonaws.com/role-arn- 2>/dev/null || true
```

Eliminar l'anotacio evita que el SDK intente usar web identity tokens.

#### 2. Pujar credencials a AWS Secrets Manager

```bash
KEY=$(sed -n 's/^aws_access_key_id=//p' ~/.aws/credentials | head -1)
SECRET=$(sed -n 's/^aws_secret_access_key=//p' ~/.aws/credentials | head -1)
TOKEN=$(sed -n 's/^aws_session_token=//p' ~/.aws/credentials | head -1)

# Crear o actualitzar el secret a Secrets Manager
aws secretsmanager create-secret \
  --name eks-efs-credentials \
  --secret-string "{\"AWS_ACCESS_KEY_ID\":\"$KEY\",\"AWS_SECRET_ACCESS_KEY\":\"$SECRET\",\"AWS_SESSION_TOKEN\":\"$TOKEN\"}" \
  --region us-east-1
```

#### 3. Crear el K8s Secret des de Secrets Manager

```bash
# Llegir de Secrets Manager
SM_VALUE=$(aws secretsmanager get-secret-value \
  --secret-id eks-efs-credentials \
  --region us-east-1 \
  --query 'SecretString' --output text)

SM_KEY=$(echo "$SM_VALUE" | python3 -c "import json,sys; print(json.load(sys.stdin)['AWS_ACCESS_KEY_ID'])")
SM_SECRET=$(echo "$SM_VALUE" | python3 -c "import json,sys; print(json.load(sys.stdin)['AWS_SECRET_ACCESS_KEY'])")
SM_TOKEN=$(echo "$SM_VALUE" | python3 -c "import json,sys; print(json.load(sys.stdin)['AWS_SESSION_TOKEN'])")

kubectl create secret generic aws-credentials \
  -n kube-system \
  --from-literal=AWS_ACCESS_KEY_ID="$SM_KEY" \
  --from-literal=AWS_SECRET_ACCESS_KEY="$SM_SECRET" \
  --from-literal=AWS_SESSION_TOKEN="$SM_TOKEN" \
  --dry-run=client -o yaml | kubectl apply -f -
```

#### 4. Injectar el Secret als containers del controller

```bash
# Obtenir el nombre de containers del deployment
NUM=$(kubectl get deploy efs-csi-controller -n kube-system \
  -o jsonpath='{.spec.template.spec.containers}' | \
  python3 -c "import json,sys; print(len(json.load(sys.stdin)))")

# Construir el patch JSON per a tots els containers
PATCH="["
for i in $(seq 0 $((NUM - 1))); do
  [ "$i" -gt 0 ] && PATCH="$PATCH,"
  PATCH="$PATCH{\"op\":\"add\",\"path\":\"/spec/template/spec/containers/$i/envFrom\",\"value\":[{\"secretRef\":{\"name\":\"aws-credentials\"}}]}"
done
PATCH="$PATCH]"

kubectl patch deploy efs-csi-controller -n kube-system --type=json -p="$PATCH"
```

#### 5. Esperar el rollout

```bash
kubectl rollout status deploy/efs-csi-controller -n kube-system --timeout=90s
```

#### 6. Verificar

```bash
kubectl exec deploy/efs-csi-controller -n kube-system -c efs-plugin -- env | grep AWS_
```

Ha de mostrar les tres variables (`AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_SESSION_TOKEN`).

## StorageClasses per provisionament dinamic

Amb les credencials injectades, el controller pot crear Access Points automaticament.
Cal definir StorageClasses amb el mode `efs-ap`:

```yaml
# WordPress (uid/gid 33 = www-data)
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: efs-sc
provisioner: efs.csi.aws.com
parameters:
  provisioningMode: efs-ap
  fileSystemId: fs-XXXXXXXX
  directoryPerms: "755"
  basePath: "/wordpress"
  uid: "33"
  gid: "33"
reclaimPolicy: Retain
volumeBindingMode: Immediate
---
# MySQL (uid/gid 999 = mysql)
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: efs-sc-mysql
provisioner: efs.csi.aws.com
parameters:
  provisioningMode: efs-ap
  fileSystemId: fs-XXXXXXXX
  directoryPerms: "700"
  basePath: "/mysql"
  uid: "999"
  gid: "999"
reclaimPolicy: Retain
volumeBindingMode: Immediate
```

### Per que dues StorageClasses?

Cada Access Point d'EFS te un **POSIX owner** (uid/gid) que determina els permisos del
directori arrel. MySQL corre com a uid 999 i WordPress com a uid 33. Si usem una sola
StorageClass amb uid 33, MySQL no pot fer `chown` del directori `/var/lib/mysql` i falla
amb:

```
chown: changing ownership of '/var/lib/mysql/': Operation not permitted
```

## PVCs sense volumeName

Amb provisionament dinamic, els PVCs **no necessiten** `volumeName`. El controller crea
automaticament el PV i l'Access Point:

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: mysql-pvc
  namespace: wordpress
spec:
  accessModes:
    - ReadWriteMany
  storageClassName: efs-sc-mysql    # Apunta a la SC correcta
  resources:
    requests:
      storage: 5Gi
  # NO volumeName → provisionament dinamic
```

## Actualitzacio de credencials

Les credencials del Learner Lab **caduquen** cada cop que el lab es reinicia. Cal
actualitzar el Secret i reiniciar el controller:

```bash
./scripts/update-aws-credentials.sh
```

Aquest script:
1. Llegeix les noves credencials de `~/.aws/credentials`
2. Actualitza el secret a AWS Secrets Manager (`eks-efs-credentials`)
3. Llegeix de Secrets Manager per actualitzar el K8s Secret `aws-credentials`
4. Reinicia el deployment `efs-csi-controller`

## Scripts

| Script | Us | Quan |
|--------|-----|------|
| `scripts/setup-efs-dynamic.sh` | Configuracio inicial | Una sola vegada despres de crear el cluster |
| `scripts/update-aws-credentials.sh` | Actualitzar credencials | Cada cop que es reinicia el Learner Lab |

## Resum: estatic vs dinamic

| Aspecte | Estatic | Dinamic |
|---------|---------|---------|
| Access Points | Manuals (AWS CLI) | Automatics (CSI controller) |
| PersistentVolumes | Manuals (YAML) | Automatics |
| volumeHandle | Cal especificar `EFS_ID::AP_ID` | Generat automaticament |
| volumeName al PVC | Necessari | No necessari |
| Requereix OIDC | No | Si (o workaround amb credencials) |
| Complexitat inicial | Alta (mes passos manuals) | Baixa (un script) |
| Escalabilitat | Nou AP manual per cada PVC | Automatic |

## Diagrama del flux

```
                    ~/.aws/credentials
                           │
                    ┌──────┴──────────────┐
                    │  AWS Secrets Manager │
                    │  (eks-efs-credentials)│
                    └──────┬──────────────┘
                           │
                    ┌──────┴──────┐
                    │  K8s Secret │
                    │  (env vars) │
                    └──────┬──────┘
                           │
                    ┌──────┴──────────┐
                    │  EFS CSI        │
                    │  Controller     │
                    │  (kube-system)  │
                    └──────┬──────────┘
                           │  AWS SDK v2
                           │  (credencials via env)
                    ┌──────┴──────┐
                    │  AWS EFS    │
                    │  API        │
                    └──────┬──────┘
                           │  Crea Access Points
                    ┌──────┴──────────────────┐
                    │  EFS File System        │
                    │  ├── /wordpress (uid 33) │
                    │  └── /mysql    (uid 999) │
                    └─────────────────────────┘
```

## Alternativa: GitHub Secrets

En lloc d'AWS Secrets Manager, es pot usar **GitHub Secrets** del repositori com a
punt central per emmagatzemar les credencials. Aquesta alternativa es util quan:

- Es vol gestionar les credencials via **CI/CD amb GitHub Actions**
- No es vol dependre d'AWS Secrets Manager (menys serveis AWS implicats)
- Es vol poder actualitzar credencials **remotament** sense acces local al cluster

### Limitacio clau

GitHub Secrets son **write-only** des de l'API. Es poden establir amb `gh secret set`
pero no es poden llegir amb `gh secret get`. Nomes son accessibles com a **variables
d'entorn** dins dels workflows de GitHub Actions.

### Flux de credencials (GitHub Secrets)

```
~/.aws/credentials → GitHub Secrets → GitHub Actions → K8s Secret → EFS CSI Controller
                          │
                          └── (write-only: no es poden llegir via API)
```

1. Les credencials es llegeixen del fitxer local `~/.aws/credentials`
2. Es pugen a GitHub Secrets amb `gh secret set` (AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY, AWS_SESSION_TOKEN)
3. El K8s Secret es crea **directament** des de les credencials locals (setup inicial)
4. Per actualitzacions remotes, un **workflow de GitHub Actions** llegeix els secrets i actualitza el K8s Secret

### Scripts alternatius

| Script | Us | Quan |
|--------|-----|------|
| `scripts/setup-efs-github-secrets.sh` | Configuracio inicial (GitHub Secrets) | Una sola vegada despres de crear el cluster |
| `scripts/update-aws-credentials-github.sh` | Actualitzar credencials (GitHub Secrets) | Cada cop que es reinicia el Learner Lab |

### Workflow de GitHub Actions

El fitxer `.github/workflows/update-efs-credentials.yml` permet actualitzar les
credencials del cluster **remotament** via `workflow_dispatch`:

```bash
# Disparar el workflow manualment
gh workflow run update-efs-credentials.yml

# Veure l'estat de l'execucio
gh run list --workflow=update-efs-credentials.yml
```

El workflow:
1. Llegeix les credencials des de GitHub Secrets (com a variables d'entorn)
2. Configura kubectl contra el cluster EKS
3. Crea/actualitza el K8s Secret `aws-credentials`
4. Reinicia el controller EFS CSI

### Comparativa: Secrets Manager vs GitHub Secrets

| Aspecte | AWS Secrets Manager | GitHub Secrets |
|---------|-------------------|----------------|
| Emmagatzematge | AWS cloud | GitHub repositori |
| Lectura via API | Si (`get-secret-value`) | No (write-only) |
| Integracio CI/CD | Via AWS CLI | Nativa (env vars) |
| Auditoria | CloudTrail | GitHub Audit Log |
| Cost | ~0.40$/mes per secret | Gratis (repos publics i privats) |
| Actualitzacio remota | Via AWS CLI | Via GitHub Actions workflow |
| Dependencia | AWS SDK/CLI | `gh` CLI |

### Diagrama del flux (GitHub Secrets)

```
                    ~/.aws/credentials
                           │
                    ┌──────┴──────────────┐
                    │   GitHub Secrets    │
                    │   (write-only)      │
                    └──────┬──────────────┘
                           │  GitHub Actions
                           │  (workflow_dispatch)
                    ┌──────┴──────┐
                    │  K8s Secret │
                    │  (env vars) │
                    └──────┬──────┘
                           │
                    ┌──────┴──────────┐
                    │  EFS CSI        │
                    │  Controller     │
                    │  (kube-system)  │
                    └──────┬──────────┘
                           │  AWS SDK v2
                           │  (credencials via env)
                    ┌──────┴──────┐
                    │  AWS EFS    │
                    │  API        │
                    └──────┬──────┘
                           │  Crea Access Points
                    ┌──────┴──────────────────┐
                    │  EFS File System        │
                    │  ├── /wordpress (uid 33) │
                    │  └── /mysql    (uid 999) │
                    └─────────────────────────┘
```
