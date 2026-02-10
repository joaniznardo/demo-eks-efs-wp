# Projecte WordPress EKS + EFS + Redis

## Context
Desplegament de WordPress sobre Amazon EKS amb persistencia EFS i sessions Redis.
Dissenyat per a comptes **AWS Academy** (LabRole, sense OIDC).

## Idioma
- Documentacio, comentaris i presentacio: **Catala**
- Noms de fitxers i variables: angles

## Estructura
```
terraform/          # EKS + EFS + SG + CSI addon (main.tf, variables.tf, outputs.tf)
k8s/                # Manifests numerats 01-05 (namespace, storageclass, mysql, redis, wordpress)
scripts/            # Bash scripts (set -euo pipefail, steps numerats [1/N], output amb "OK")
presentacio/        # Reveal.js (index.html)
.github/workflows/  # GitHub Actions (update-efs-credentials.yml)
```

## Patrons clau
- **AWS Academy**: no OIDC, tot amb LabRole, credencials temporals de ~/.aws/credentials
- **EFS CSI workaround**: injectar credencials com env vars al controller (maxima prioritat SDK v2)
- **Dues opcions de centralitzacio**: AWS Secrets Manager o GitHub Secrets (write-only)
- **Dues StorageClasses**: efs-sc (uid 33, WordPress) i efs-sc-mysql (uid 999, MySQL)
- **MySQL sobre EFS**: --innodb-use-native-aio=0 --innodb-flush-method=fsync
- **WordPress auto-install**: WP-CLI al setup.sh (ConfigMap), no mu-plugin
- **Redis sessions**: mu-plugin redis-sessions.php + pecl install redis

## Scripts
| Script | Funcio |
|--------|--------|
| setup-efs-dynamic.sh | Setup inicial (AWS Secrets Manager) |
| update-aws-credentials.sh | Actualitzar credencials (AWS Secrets Manager) |
| setup-efs-github-secrets.sh | Setup inicial (GitHub Secrets) |
| update-aws-credentials-github.sh | Actualitzar credencials (GitHub Secrets, --remote per GH Actions) |

## Configuracio
- Regio: us-east-1
- Cluster: wordpress-eks (v1.31, 2 nodes t3.medium)
- Namespace app: wordpress
- Namespace sistema: kube-system (controller EFS CSI, secret aws-credentials)
- Secret SM: eks-efs-credentials
- Credencials WP: admin / Wp@Eks2026Secure
