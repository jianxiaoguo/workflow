#!/usr/bin/env bash
set -eo pipefail
shopt -s expand_aliases

# initArch discovers the architecture for this system.
init_arch() {
  ARCH=$(uname -m)
  case $ARCH in
    armv5*) ARCH="armv5";;
    armv6*) ARCH="armv6";;
    armv7*) ARCH="arm";;
    aarch64) ARCH="arm64";;
    x86) ARCH="386";;
    x86_64) ARCH="amd64";;
    i686) ARCH="386";;
    i386) ARCH="386";;
  esac
}

function clean_before_exit {
    # delay before exiting, so stdout/stderr flushes through the logging system
    rm -rf /tmp/drycc-values.yaml /etc/rancher/k3s/registries.yaml
    configure_registries runtime
    sleep 3
}
trap clean_before_exit EXIT
init_arch

function install_helm {
  if [[ "${INSTALL_DRYCC_MIRROR}" == "cn" ]] ; then
    version=$(curl -Ls https://drycc-mirrors.drycc.cc/helm/helm/releases|grep /helm/helm/releases/tag/ | sed -E 's/.*\/helm\/helm\/releases\/tag\/(v[0-9\.]{1,}(-rc.[0-9]{1,})?)".*/\1/g' | head -1)
    tar_name="helm-${version}-linux-${ARCH}.tar.gz"
    helm_download_url="https://drycc-mirrors.drycc.cc/helm/${tar_name}"
  else
    version=$(curl -Ls https://github.com/helm/helm/releases|grep /helm/helm/releases/tag/ | sed -E 's/.*\/helm\/helm\/releases\/tag\/(v[0-9\.]{1,}(-rc.[0-9]{1,})?)".*/\1/g' | head -1)
    tar_name="helm-${version}-linux-${ARCH}.tar.gz"
    helm_download_url="https://get.helm.sh/${tar_name}"
  fi
  curl -fsSL -o "${tar_name}" "${helm_download_url}"
  tar -zxvf "${tar_name}"
  mv "linux-${ARCH}/helm" /usr/local/bin/helm
  rm -rf "${tar_name}" "linux-${ARCH}"
  helm repo add --force-update drycc https://charts.drycc.cc/${CHANNEL:-stable}
}

function configure_os {
  iptables -F
  iptables -X
  iptables -F -t nat
  iptables -X -t nat
  iptables -P FORWARD ACCEPT
  swapoff -a
  sed -i '/ swap / s/^\(.*\)$/#\1/g' /etc/fstab
  mount bpffs -t bpf /sys/fs/bpf
}

function configure_registries {
  mkdir -p /etc/rancher/k3s
  if [[ "$1" == "runtime" ]] ; then
    if [[ -f "${REGISTRIES_FILE}" ]] ; then
      cat "${REGISTRIES_FILE}" > /etc/rancher/k3s/registries.yaml
    elif [[ "${INSTALL_DRYCC_MIRROR}" == "cn" ]] ; then
      cat << EOF > "/etc/rancher/k3s/registries.yaml"
mirrors:
  "docker.io":
    endpoint:
    - "https://hub-mirror.c.163.com"
    - "https://registry-1.docker.io"
EOF
    fi
  else
    cat << EOF > "/etc/rancher/k3s/registries.yaml"
mirrors:
  "docker.io":
    endpoint:
    - "https://gcr-mirror.drycc.cc"
    - "https://registry-1.docker.io"
  "quay.io":
    endpoint:
    - "https://quay-mirror.drycc.cc"
    - "https://quay.io"
  "gcr.io":
    endpoint:
    - "https://gcr-mirror.drycc.cc"
    - "https://gcr.io"
  "k8s.gcr.io":
    endpoint:
    - "https://k8s-mirror.drycc.cc"
    - "https://k8s.gcr.io"
EOF
  fi
}

function configure_mirrors {
  if [[ "${INSTALL_DRYCC_MIRROR}" == "cn" ]] ; then
    configure_registries
    INSTALL_K3S_MIRROR="${INSTALL_DRYCC_MIRROR}"
    export INSTALL_K3S_MIRROR
    k3s_install_url="http://rancher-mirror.cnrancher.com/k3s/k3s-install.sh"
  else
    k3s_install_url="https://get.k3s.io"
  fi
}

function install_k3s_server {
  configure_os
  configure_mirrors
  INSTALL_K3S_EXEC="server ${INSTALL_K3S_EXEC} --flannel-backend=none --disable=traefik --disable-kube-proxy --disable=local-storage --disable=servicelb --cluster-cidr=10.233.0.0/16"
  if [[ -n "${K3S_DATA_DIR}" ]] ; then
    INSTALL_K3S_EXEC="$INSTALL_K3S_EXEC --data-dir=${K3S_DATA_DIR}/rancher/k3s"
  fi
  if [[ -z "${K3S_URL}" ]] ; then
    INSTALL_K3S_EXEC="$INSTALL_K3S_EXEC --cluster-init"
  fi
  curl -sfL "${k3s_install_url}" |INSTALL_K3S_EXEC="$INSTALL_K3S_EXEC" sh -s -
}

function install_k3s_agent {
  configure_os
  configure_mirrors
  if [[ -n "${K3S_DATA_DIR}" ]] ; then
    INSTALL_K3S_EXEC="$INSTALL_K3S_EXEC --data-dir=${K3S_DATA_DIR}/rancher/k3s"
  fi
  curl -sfL "${k3s_install_url}" |INSTALL_K3S_EXEC="$INSTALL_K3S_EXEC" sh -s -
}

function install_components {
  helm repo update

  echo -e "\\033[32m---> Waiting for helm to install components...\\033[0m"
  api_server=(`kubectl config view -o=jsonpath='{.clusters[0].cluster.server}' | tr "://" " "`)
  helm install cilium drycc/cilium \
    --set tunnel=geneve \
    --set operator.replicas=1 \
    --set bandwidthManager=true \
    --set kubeProxyReplacement=strict \
    --set k8sServiceHost=${api_server[1]} \
    --set k8sServicePort=${api_server[2]} \
    --set hostPort.enabled=true \
    --namespace kube-system --wait
  helm install metallb drycc/metallb --namespace metallb --create-namespace --wait -f - <<EOF
configInline:
  address-pools:
   - name: default
     protocol: layer2
     addresses:
     - ${METALLB_ADDRESS_POOLS:-172.16.0.0/12}
EOF
  helm install traefik drycc/traefik \
    --set ssl.enabled=true \
    --set ingressClass.enabled=true \
    --set ingressClass.isDefaultClass=true \
    --namespace traefik \
    --create-namespace --wait
  helm install cert-manager drycc/cert-manager --namespace cert-manager --create-namespace --set installCRDs=true --wait
  helm install catalog drycc/catalog \
    --set asyncBindingOperationsEnabled=true \
    --set image=docker.io/drycc/service-catalog:canary \
    --namespace catalog \
    --create-namespace --wait
}

function install_openebs {
  helm install openebs drycc/openebs \
    --namespace openebs \
    --create-namespace \
    --set nfs-provisioner.enabled=true --wait
  kubectl patch storageclass ${DEFAULT_STORAGE_CLASS:-"openebs-hostpath"} \
    -p '{"metadata": {"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'
}

function check_drycc_env {
  if [[ -z "${PLATFORM_DOMAIN}" ]] ; then
    echo -e "\\033[31m---> Please set the PLATFORM_DOMAIN variable.\\033[0m"
    echo -e "\\033[31m---> For example:\\033[0m"
    echo -e "\\033[31m---> export PLATFORM_DOMAIN=drycc.cc\\033[0m"
    echo -e "\\033[31m---> And confirm that wildcard domain name resolution has been set.\\033[0m"
    echo -e "\\033[31m---> For example, the current server IP is 8.8.8.8\\033[0m"
    echo -e "\\033[31m---> Please point *.drycc.cc to 8.8.8.8\\033[0m"
    exit 1
  fi

  if [[ -z "${DRYCC_ADMIN_USERNAME}" || -z "${DRYCC_ADMIN_PASSWORD}" ]] ; then
    echo -e "\\033[31m---> Please set the DRYCC_ADMIN_USERNAME and DRYCC_ADMIN_PASSWORD variable.\\033[0m"
    echo -e "\\033[31m---> For example:\\033[0m"
    echo -e "\\033[31m---> export DRYCC_ADMIN_USERNAME=admin\\033[0m"
    echo -e "\\033[31m---> export DRYCC_ADMIN_PASSWORD=admin\\033[0m"
    echo -e "\\033[31m---> This password is used by end users to log in and manage drycc.\\033[0m"
    echo -e "\\033[31m---> Please set a high security string!!!\\033[0m"
    exit 1
  fi
}

function install_drycc {
  check_drycc_env
  echo -e "\\033[32m---> Start installing workflow...\\033[0m"

  RABBITMQ_USERNAME=$(cat /proc/sys/kernel/random/uuid)
  RABBITMQ_PASSWORD=$(cat /proc/sys/kernel/random/uuid)
  if [[ "${INSTALL_DRYCC_MIRROR}" == "cn" ]] ; then
    cat << EOF > "/tmp/drycc-values.yaml"
imagebuilder:
  container_registries: |
    unqualified-search-registries = ["docker.io"]
    short-name-mode="permissive"
    [[registry]]
    prefix = "docker.io"
    location = "registry-1.docker.io"
    [[registry.mirror]]
    prefix = "docker.io"
    location = "hub-mirror.c.163.com"
EOF
  else
    cat << EOF > "/tmp/drycc-values.yaml"
imagebuilder:
  container_registries: |
    unqualified-search-registries = ["docker.io"]
    short-name-mode="permissive"
EOF
  fi
  helm install drycc drycc/workflow \
    --set builder.service.type=LoadBalancer \
    --set global.clusterDomain="cluster.local" \
    --set global.platformDomain="${PLATFORM_DOMAIN}" \
    --set global.certManagerEnabled=${CERT_MANAGER_ENABLED:-true} \
    --set global.ingressClass=traefik \
    --set fluentd.daemonEnvironment.CONTAINER_TAIL_PARSER_TYPE="/^(?<time>.+) (?<stream>stdout|stderr)( (?<tags>.))? (?<log>.*)$/" \
    --set controller.appStorageClass=${CONTROLLER_APP_STORAGE_CLASS:-"openebs-kernel-nfs"} \
    --set minio.persistence.enabled=true \
    --set minio.persistence.size=${MINIO_PERSISTENCE_SIZE:-20Gi} \
    --set minio.persistence.storageClass=${MINIO_PERSISTENCE_STORAGE_CLASS:-""} \
    --set rabbitmq.username="${RABBITMQ_USERNAME}" \
    --set rabbitmq.password="${RABBITMQ_PASSWORD}" \
    --set rabbitmq.persistence.enabled=true \
    --set rabbitmq.persistence.size=${RABBITMQ_PERSISTENCE_SIZE:-5Gi} \
    --set rabbitmq.persistence.storageClass=${RABBITMQ_PERSISTENCE_STORAGE_CLASS:-""} \
    --set influxdb.persistence.enabled=true \
    --set influxdb.persistence.size=${INFLUXDB_PERSISTENCE_SIZE:-5Gi} \
    --set influxdb.persistence.storageClass=${INFLUXDB_PERSISTENCE_STORAGE_CLASS:-""} \
    --set monitor.grafana.persistence.enabled=true \
    --set monitor.grafana.persistence.size=${MONITOR_GRAFANA_PERSISTENCE_SIZE:-5Gi} \
    --set monitor.grafana.storageClass=${MONITOR_GRAFANA_PERSISTENCE_STORAGE_CLASS:-""} \
    --set passport.adminUsername=${DRYCC_ADMIN_USERNAME} \
    --set passport.adminPassword=${DRYCC_ADMIN_PASSWORD} \
    --namespace drycc \
    --values /tmp/drycc-values.yaml \
    --create-namespace --wait --timeout 30m0s
  echo -e "\\033[32m---> Rabbitmq username: $RABBITMQ_USERNAME\\033[0m"
  echo -e "\\033[32m---> Rabbitmq password: $RABBITMQ_PASSWORD\\033[0m"
}

function install_helmbroker {
  if [[ "${INSTALL_DRYCC_MIRROR}" == "cn" ]] ; then
    addons_url="https://drycc-mirrors.drycc.cc/drycc/addons/releases/download/latest/index.yaml"
  else
    addons_url="https://github.com/drycc/addons/releases/download/latest/index.yaml"
  fi
  HELMBROKER_USERNAME=$(cat /proc/sys/kernel/random/uuid)
  HELMBROKER_PASSWORD=$(cat /proc/sys/kernel/random/uuid)

  echo -e "\\033[32m---> Start installing helmbroker...\\033[0m"

  helm install helmbroker drycc/helmbroker \
    --set ingressClass="traefik" \
    --set platformDomain="cluster.local" \
    --set persistence.size=${HELMBROKER_PERSISTENCE_SIZE:-5Gi} \
    --set persistence.storageClass=${HELMBROKER_PERSISTENCE_STORAGE_CLASS:-"openebs-kernel-nfs"} \
    --set platformDomain=${PLATFORM_DOMAIN} \
    --set certManagerEqnabled=${CERT_MANAGER_ENABLED:-true} \
    --set username=${HELMBROKER_USERNAME} \
    --set password=${HELMBROKER_PASSWORD} \
    --set environment.HELMBROKER_CELERY_BROKER="amqp://${RABBITMQ_USERNAME}:${RABBITMQ_PASSWORD}@drycc-rabbitmq.drycc.svc.cluster.local:5672/drycc" \
    --namespace drycc --create-namespace --wait -f - <<EOF
repositories:
- name: drycc-helm-broker
  url: ${addons_url}
EOF
  if [[ "${CERT_MANAGER_ENABLED:-true}" == "true" ]] ; then
    BROKER_URL="https://${HELMBROKER_USERNAME}:${HELMBROKER_PASSWORD}@drycc-helmbroker.${PLATFORM_DOMAIN}"
  else
    BROKER_URL="http://${HELMBROKER_USERNAME}:${HELMBROKER_PASSWORD}@drycc-helmbroker.${PLATFORM_DOMAIN}"
  fi

  kubectl apply -f - <<EOF
apiVersion: servicecatalog.k8s.io/v1beta1
kind: ClusterServiceBroker
metadata:
  finalizers:
  - kubernetes-incubator/service-catalog
  generation: 1
  labels:
    app.kubernetes.io/managed-by: Helm
    heritage: Helm
  name: helmbroker
spec:
  relistBehavior: Duration
  relistRequests: 5
  url: ${BROKER_URL}
EOF

  echo -e "\\033[32m---> Helmbroker username: $HELMBROKER_USERNAME\\033[0m"
  echo -e "\\033[32m---> Helmbroker password: $HELMBROKER_PASSWORD\\033[0m"
}

function configure_haproxy {
  BUILDER_IP=$(kubectl get svc drycc-builder -n drycc -o="jsonpath={.status.loadBalancer.ingress[0].ip}")
  INGRESS_IP=$(kubectl get svc traefik -n traefik -o="jsonpath={.status.loadBalancer.ingress[0].ip}")

  if [[ "${USE_HAPROXY:-true}" == "true" ]] ; then
    cat << EOF > "/etc/haproxy/haproxy.cfg"
global
   log /dev/log    local0
   log /dev/log    local1 notice
   chroot /var/lib/haproxy
   stats socket /run/haproxy/admin.sock mode 660 level admin expose-fd listeners
   stats timeout 30s
   user haproxy
   group haproxy
   daemon
listen http
   bind *:${HAPROXY_HTTP_PORT:-80}
   mode tcp
   maxconn 100000
   timeout connect 60s
   timeout client  30000
   timeout server  30000
   server ingress ${INGRESS_IP}:80 check
listen https
   bind *:${HAPROXY_HTTPS_PORT:-443}
   mode tcp
   maxconn 100000
   timeout connect 60s
   timeout client  30000
   timeout server  30000
   server ingress ${INGRESS_IP}:443 check
listen builder
   bind *:${HAPROXY_BUILDER_PORT:-2222}
   mode tcp
   maxconn 100000
   timeout connect 60s
   timeout client  30000
   timeout server  30000
   server builder ${BUILDER_IP}:2222 check
EOF
  fi

  mkdir -p /run/haproxy
  systemctl enable haproxy
  systemctl restart haproxy
}

export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

if [[ -z "$@" ]] ; then
  install_k3s_server
  install_helm
  install_components
  install_openebs
  install_drycc
  configure_haproxy
  install_helmbroker
  echo -e "\\033[32m---> Installation complete, enjoy life...\\033[0m"
else
  for command in "$@"
  do
      $command
      echo -e "\\033[32m---> Execute $command complete, enjoy life...\\033[0m"
  done
fi
