# WordPress on EKS amb EFS i Redis

Desplegament de WordPress sobre Amazon EKS amb persistencia EFS i sessions Redis.
Dissenyat per a comptes **AWS Academy** (utilitza el rol `LabRole`).

## Arquitectura

```
                    ┌─────────────────────────────────────────┐
                    │           VPC per defecte (us-east-1)   │
                    │                                         │
                    │  ┌──────────┐       ┌──────────┐       │
                    │  │  AZ - a  │       │  AZ - b  │       │
                    │  └────┬─────┘       └────┬─────┘       │
                    │       │                  │              │
                    │  ┌────┴──────────────────┴────┐        │
                    │  │        EKS Cluster          │        │
                    │  │                             │        │
                    │  │  ┌───────────┐ ┌─────────┐ │        │
                    │  │  │ WordPress │ │WordPress│ │        │
                    │  │  │ (replica) │ │(replica)│ │        │
                    │  │  └─────┬─────┘ └────┬────┘ │        │
                    │  │        │             │      │        │
                    │  │  ┌─────┴─────┐ ┌────┴───┐  │        │
                    │  │  │   MySQL   │ │ Redis  │  │        │
                    │  │  └─────┬─────┘ └────────┘  │        │
                    │  └────────┼────────────────────┘        │
                    │           │                              │
                    │  ┌────────┴────────┐                    │
                    │  │  Amazon EFS     │                    │
                    │  │  (persistencia) │                    │
                    │  └─────────────────┘                    │
                    └─────────────────────────────────────────┘
```

## Components

| Component | Descripcio |
|-----------|-----------|
| **EKS** | Cluster Kubernetes gestionat, 2 nodes t3.medium |
| **EFS** | Sistema de fitxers compartit amb provisionament dinamic (Access Points automatics) |
| **WordPress** | 2 repliques amb auto-instal·lacio via WP-CLI al `setup.sh` |
| **MySQL 8.0** | Base de dades amb persistencia EFS (StorageClass dedicada uid 999) |
| **Redis 7** | Cache de sessions PHP centralitzades |

## Fitxers del projecte

```
terraform/
  main.tf              # EKS + EFS + SG + Addon CSI (LabRole)
  variables.tf         # region, cluster_name, eks_version
  outputs.tf           # efs_id, comandes utils
k8s/
  01-namespace.yaml    # Namespace wordpress
  02-storageclass.yaml # StorageClasses EFS dinamic (WordPress uid=33, MySQL uid=999)
  03-mysql.yaml        # PVC + Deployment + Service headless
  04-redis.yaml        # Deployment + Service
  05-wordpress.yaml    # ConfigMap (setup.sh + redis-sessions.php) + PVC + Deploy + LB
scripts/
  setup-efs-dynamic.sh       # Configuracio inicial del provisionament dinamic
  update-aws-credentials.sh  # Actualitzar credencials quan el lab es reinicia
dynamic-efs.md         # Explicacio detallada del provisionament dinamic
troubleshoot.md        # Problemes trobats i solucions
README.md              # Aquesta guia
presentacio/
  index.html           # Presentacio reveal.js
```

## Prerequisites

- Compte AWS Academy amb Lab iniciat
- AWS CLI configurat (o AWS CloudShell)
- Terraform >= 1.5
- kubectl

## Pas 1: Iniciar el Lab AWS Academy

1. Accedeix a AWS Academy i inicia el lab
2. Copia les credencials AWS al fitxer `~/.aws/credentials`:

```bash
aws configure
# O copia directament les credencials del lab
```

## Pas 2: Desplegar la infraestructura amb Terraform

```bash
cd terraform

# Inicialitzar Terraform
terraform init

# Revisar el pla
terraform plan

# Aplicar (tarda ~15-20 minuts)
terraform apply -auto-approve
```

> **Nota:** La creacio del cluster EKS tarda uns 7-10 minuts i el node group uns 3-5 minuts mes.

Terraform crea 7 recursos:

| Recurs | Descripcio |
|--------|-----------|
| `aws_security_group.efs` | SG que permet NFS (port 2049) des de la VPC |
| `aws_eks_cluster.main` | Cluster EKS v1.31 amb LabRole |
| `aws_eks_node_group.main` | 2 nodes t3.medium en 2 AZs |
| `aws_efs_file_system.main` | Sistema de fitxers EFS |
| `aws_efs_mount_target.main` x2 | Mount targets (1 per subnet/AZ) |
| `aws_eks_addon.efs_csi` | Driver EFS CSI per Kubernetes |

## Pas 3: Configurar kubectl

```bash
# Copiar la comanda de l'output de Terraform
aws eks update-kubeconfig --region us-east-1 --name wordpress-eks

# Verificar connexio
kubectl get nodes
```

Hauries de veure 2 nodes en estat `Ready`.

## Pas 4: Configurar el provisionament dinamic EFS

AWS Academy no te OIDC provider, per tant cal injectar les credencials AWS al
controller EFS CSI perque puga crear Access Points automaticament.

Les credencials es centralitzen a **AWS Secrets Manager** per facilitar la comparticio
entre equips i mantenir un unic punt de veritat.

```bash
# Executar l'script de configuracio (una sola vegada)
./scripts/setup-efs-dynamic.sh
```

L'script fa 6 accions:
1. Elimina l'anotacio IRSA del Service Account del controller
2. Llegeix les credencials de `~/.aws/credentials`
3. Crea/actualitza el secret a AWS Secrets Manager (`eks-efs-credentials`)
4. Llegeix de Secrets Manager per crear el K8s Secret `aws-credentials`
5. Injecta el Secret com a variables d'entorn als containers del controller
6. Reinicia el controller

> **Detalls:** Consulta [dynamic-efs.md](dynamic-efs.md) per una explicacio completa.

## Pas 5: Actualitzar l'EFS ID als StorageClasses

```bash
# Obtenir EFS ID
EFS_ID=$(cd terraform && terraform output -raw efs_id)

# Actualitzar el fileSystemId als StorageClasses
sed -i "s/fileSystemId: .*/fileSystemId: $EFS_ID/" k8s/02-storageclass.yaml

# Verificar
grep fileSystemId k8s/02-storageclass.yaml
```

## Pas 6: Desplegar WordPress a Kubernetes

```bash
# Aplicar tots els manifests
kubectl apply -f k8s/

# Verificar els recursos
kubectl get all,pvc -n wordpress
```

## Pas 7: Esperar al desplegament

```bash
# Esperar que els pods estiguen llests
kubectl wait --for=condition=ready pod -l app=mysql -n wordpress --timeout=300s
kubectl wait --for=condition=ready pod -l app=redis -n wordpress --timeout=120s
kubectl wait --for=condition=ready pod -l app=wordpress -n wordpress --timeout=300s
```

> **Nota:** El primer arrencament de WordPress tarda ~1-2 minuts extra perque:
> 1. Instal·la l'extensio PHP Redis via PECL
> 2. Descarrega WP-CLI
> 3. Executa `wp core install` automaticament

## Pas 8: Actualitzar la URL de WordPress

```bash
# Obtenir la URL del LoadBalancer
LB_URL=$(kubectl get svc wordpress -n wordpress -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
echo "URL: http://$LB_URL"

# Actualitzar la URL de WordPress a la base de dades
kubectl exec deploy/wordpress -n wordpress -- wp option update siteurl "http://$LB_URL" --allow-root
kubectl exec deploy/wordpress -n wordpress -- wp option update home "http://$LB_URL" --allow-root
```

## Pas 9: Accedir a WordPress

Obre `http://<EXTERNAL-IP>` al navegador. WordPress ja estara instal·lat automaticament.

**Credencials per defecte:**

| Camp | Valor |
|------|-------|
| URL admin | `http://<EXTERNAL-IP>/wp-admin` |
| Usuari | `admin` |
| Contrasenya | `Wp@Eks2026Secure` |

## Quan el lab es reinicia

Les credencials del Learner Lab caduquen quan el lab es reinicia. Cal actualitzar-les:

```bash
./scripts/update-aws-credentials.sh
```

## Verificacions

### Comprovar persistencia EFS (provisionament dinamic)

```bash
# Veure els PVCs (han d'estar Bound)
kubectl get pvc -n wordpress

# Veure els PVs (creats automaticament pel controller)
kubectl get pv
```

### Comprovar Redis

```bash
# Verificar extensio Redis carregada al pod
kubectl exec deploy/wordpress -n wordpress -- php -r "echo extension_loaded('redis') ? 'OK' : 'FAIL';"

# Test de connexio Redis
kubectl exec deploy/wordpress -n wordpress -- php -r "
\$r = new Redis();
\$r->connect('redis.wordpress.svc.cluster.local', 6379);
\$r->set('test','ok');
echo \$r->get('test');
"

# Monitor de Redis en temps real
kubectl exec -it deploy/redis -n wordpress -- redis-cli monitor
```

### Veure logs de WordPress

```bash
kubectl logs deploy/wordpress -n wordpress
```

### Escalar WordPress

```bash
# Escalar a 3 repliques (EFS permet ReadWriteMany)
kubectl scale deploy/wordpress -n wordpress --replicas=3
```

## Neteja

```bash
# 1. Eliminar els recursos Kubernetes
kubectl delete -f k8s/

# 2. Destruir la infraestructura
cd terraform
terraform destroy -auto-approve
```

> **Nota:** Els Access Points creats dinamicament pel controller es netegen amb els PVs.
> Si `reclaimPolicy: Retain`, cal eliminar-los manualment des de la consola AWS o amb
> `aws efs delete-access-point`.

## Resolucio de problemes

Consulta el fitxer [troubleshoot.md](troubleshoot.md) per una llista detallada dels problemes
coneguts i les solucions aplicades durant el desplegament.
