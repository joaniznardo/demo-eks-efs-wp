# Troubleshooting - WordPress on EKS amb EFS

Recopilacio dels problemes trobats durant el desplegament i les solucions aplicades.

---

## Problema 1: Provisionament dinamic EFS falla (OIDC provider)

### Simptomes

Els PVCs queden en estat `Pending` indefinidament. Els events del PVC mostren:

```
Warning  ProvisioningFailed  efs.csi.aws.com  rpc error: code = Internal
desc = Failed to fetch Access Points or Describe File System:
InvalidIdentityToken: No OpenIDConnect provider found in your account for
https://oidc.eks.us-east-1.amazonaws.com/id/XXXXXXXXX
```

### Causa

L'addon EFS CSI Driver intenta autenticar-se via **IRSA** (IAM Roles for Service Accounts),
que requereix un **OIDC Identity Provider** registrat al compte AWS. Els comptes d'**AWS Academy
no tenen OIDC provider** configurat i LabRole no permet crear-ne un (`iam:CreateOpenIDConnectProvider`).

### Solucio aplicada: Injectar credencials AWS al controller

En lloc de dependre d'IRSA/OIDC, s'injecten les credencials del Learner Lab com a
**variables d'entorn** als containers del controller EFS CSI. L'AWS SDK v2 prioritza
les variables d'entorn per sobre dels web identity tokens (IRSA), per tant el controller
pot autenticar-se directament.

```bash
# Configuracio inicial (una sola vegada)
./scripts/setup-efs-dynamic.sh
```

L'script:
1. Elimina l'anotacio IRSA del Service Account (`eks.amazonaws.com/role-arn-`)
2. Crea un Secret `aws-credentials` amb `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_SESSION_TOKEN`
3. Patcheja el deployment per injectar el Secret via `envFrom`
4. Reinicia el controller

> **Detalls complets:** Consulta [dynamic-efs.md](dynamic-efs.md)

### Per que funciona

L'AWS SDK v2 resol credencials en aquest ordre:
1. Variables d'entorn (AWS_ACCESS_KEY_ID, etc.) **<-- les injectem aqui**
2. Fitxer de credencials
3. Web Identity Token (IRSA) <-- falla sense OIDC
4. EC2 IMDS

Com que les variables d'entorn tenen prioritat maxima, el SDK les usa directament
sense intentar IRSA.

### Nota: credencials temporals

Les credencials del Learner Lab caduquen quan el lab es reinicia. Cal executar:

```bash
./scripts/update-aws-credentials.sh
```

---

## Problema 2: Auto-instal·lacio WordPress via mu-plugin falla

### Simptomes

WordPress mostra `Error establishing a database connection` o
`One or more database tables are unavailable. The database may need to be repaired.`

L'intent d'auto-instal·lacio via mu-plugin (`auto-install.php`) creava les taules
pero no completava la insercion de dades (la taula `wp_options` tenia nomes 1 registre
en lloc dels ~100+ necessaris).

### Causa

La funcio `wp_install()` no funciona correctament quan es crida des d'un **mu-plugin**.
Els mu-plugins es carreguen molt aviat en el bootstrap de WordPress (`wp-settings.php`),
en un moment on algunes funcions necessaries per `wp_install()` encara no estan
completament inicialitzades. El resultat es una instal·lacio parcial: les taules es
creen pero les dades inicials no s'insereixen correctament.

### Solucio aplicada: WP-CLI al setup.sh

Es va substituir el mu-plugin `auto-install.php` per logica d'instal·lacio dins del
script d'arrencada `setup.sh` (ConfigMap), que usa **WP-CLI** per fer la instal·lacio
despres que WordPress estiga completament inicialitzat.

```bash
# setup.sh (fragments rellevants)

# Inicia WordPress en segon pla
docker-entrypoint.sh apache2-foreground &
WP_PID=$!

# Espera que els fitxers WP estiguen copiats
until [ -f /var/www/html/wp-includes/version.php ]; do sleep 2; done

# Descarrega WP-CLI
curl -sO https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar
chmod +x wp-cli.phar && mv wp-cli.phar /usr/local/bin/wp

# Espera que MySQL estiga disponible
until wp db check --path=/var/www/html --allow-root > /dev/null 2>&1; do sleep 3; done

# Instal·la WordPress si no esta instal·lat (lock en EFS)
LOCK=/var/www/html/.wp-installed.lock
if ! wp core is-installed --path=/var/www/html --allow-root 2>/dev/null; then
  if [ ! -f "$LOCK" ]; then
    touch "$LOCK"
    wp core install \
      --url="http://localhost" \
      --title="WordPress on EKS" \
      --admin_user=admin \
      --admin_password="Wp@Eks2026Secure" \
      --admin_email=admin@example.com \
      --path=/var/www/html \
      --allow-root
  fi
fi

# Espera el proces principal
wait $WP_PID
```

### Per que funciona

WP-CLI executa `wp core install` com un proces independent que carrega WordPress
completament abans de cridar la funcio d'instal·lacio. A mes, el lock file a EFS
evita race conditions entre les 2 repliques de WordPress.

---

## Problema 3: MySQL sobre EFS/NFS

### Simptomes

MySQL pot fallar a l'arrencada o tenir rendiment molt baix sobre volums EFS.

### Causa

MySQL InnoDB utilitza per defecte:
- **Native AIO** (Asynchronous I/O): no suportat per NFS
- **O_DIRECT** per flush: no funciona be sobre NFS

### Solucio aplicada

Afegir arguments a MySQL que desactiven les funcionalitats incompatibles amb NFS:

```yaml
containers:
  - name: mysql
    image: mysql:8.0
    args:
      - --default-authentication-plugin=mysql_native_password
      - --innodb-use-native-aio=0      # Desactiva AIO natiu
      - --innodb-flush-method=fsync     # Usa fsync en lloc de O_DIRECT
```

### Consideracio

EFS/NFS no es ideal per bases de dades. Per a entorns de produccio, es recomana
usar **Amazon EBS** (via EBS CSI Driver) o **Amazon RDS** per a MySQL.

---

## Problema 4: URL de WordPress apunta a localhost

### Simptomes

Despres de la instal·lacio automatica, WordPress te `siteurl` i `home` configurats
com `http://localhost`. Aixo fa que els links interns no funcionen correctament
quan s'accedeix des del navegador via el LoadBalancer.

### Causa

L'script `setup.sh` instal·la WordPress amb `--url="http://localhost"` perque en el
moment de la instal·lacio encara no coneix la URL del LoadBalancer (que tarda uns
minuts a aprovisionar-se).

### Solucio aplicada

Actualitzar manualment la URL despres del desplegament amb WP-CLI:

```bash
LB_URL=$(kubectl get svc wordpress -n wordpress \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')

kubectl exec deploy/wordpress -n wordpress -- \
  wp option update siteurl "http://$LB_URL" --allow-root

kubectl exec deploy/wordpress -n wordpress -- \
  wp option update home "http://$LB_URL" --allow-root
```

---

## Problema 5: WordPress tarda a arrencar

### Simptomes

El primer arrencament de cada pod WordPress tarda ~1-2 minuts mes del normal.

### Causa

L'script `setup.sh` fa tres operacions costoses a l'inici:

1. **`pecl install redis`**: Compila l'extensio PHP Redis des del codi font (~30-60s)
2. **Descarrega WP-CLI**: Baixa el fitxer phar des de GitHub (~5s)
3. **`wp core install`**: Crea taules i insereix dades inicials (~5s)

### Solucio

Per a entorns de produccio, es recomanable crear una **imatge Docker personalitzada**
que ja inclogui l'extensio Redis i WP-CLI preinstal·lats:

```dockerfile
FROM wordpress:6.7-php8.3-apache
RUN pecl install redis && docker-php-ext-enable redis
RUN curl -sO https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar \
    && chmod +x wp-cli.phar && mv wp-cli.phar /usr/local/bin/wp
```

Aixo reduiria el temps d'arrencada de ~90s a ~10s.

---

## Problema 6: MySQL chown falla amb provisionament dinamic

### Simptomes

MySQL no arrenca i mostra l'error:

```
chown: changing ownership of '/var/lib/mysql/': Operation not permitted
```

### Causa

Quan s'usa una sola StorageClass amb `uid: "33"` (www-data) per a tots els PVCs,
l'Access Point de MySQL es crea amb propietari uid 33. MySQL (que corre com uid 999)
no pot fer `chown` del directori perque EFS Access Points imposen el POSIX owner.

### Solucio aplicada

Crear una **StorageClass separada per MySQL** amb uid/gid 999:

```yaml
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
```

I el PVC de MySQL apunta a aquesta StorageClass:

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: mysql-pvc
spec:
  storageClassName: efs-sc-mysql   # <-- StorageClass amb uid 999
```

---

## Resum de canvis respecte al disseny original

| Aspecte | Disseny original | Solucio final |
|---------|-----------------|---------------|
| EFS provisioning | Dinamic (fallava per OIDC) | Dinamic amb credencials injectades |
| Autenticacio CSI | IRSA (OIDC) | Variables d'entorn (AWS Secret) |
| StorageClasses | Una sola | Dues: `efs-sc` (uid 33) + `efs-sc-mysql` (uid 999) |
| Auto-instal·lacio | mu-plugin `auto-install.php` amb `wp_install()` | WP-CLI dins `setup.sh` |
| URL WordPress | Automatica | Manual amb `wp option update` post-desplegament |
| Access Points | Manuals (AWS CLI) | Automatics (CSI controller) |
| PersistentVolumes | Manuals (YAML) | Automatics |
