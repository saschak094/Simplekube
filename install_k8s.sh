#! /bin/bash
# -----------------------
# Set ip up :
# -----------------------
k8sVersion="v1.7.3"
etcdVersion="v3.2.5"
dockerVersion="17.05.0-ce"
cniVersion="v0.5.2"
calicoCniVersion="v1.10.0"
calicoctlVersion="v1.3.0"
cfsslVersion="v1.2.0"
helmVersion="v2.6.0"
hostIP="internalIP"
clusterDomain="cluster.default"

adminToken="maeshah8Xee9ema9xahwohlaek9evoep3edaihio9Theib3ohSh7phoh9zo5aiv3"
kubeletToken="ooshoovoh2quee0fe2OoshukaiNg9nooveiGaechiothiyequiel2uphie0uenai"

hostname=$(cat /etc/hostname)

## Let's go :
# ----------------------
## Certs
wget https://pkg.cfssl.org/R1.2/cfssl_linux-amd64
chmod +x cfssl_linux-amd64
sudo mv cfssl_linux-amd64 /usr/local/bin/cfssl
wget https://pkg.cfssl.org/R1.2/cfssljson_linux-amd64
chmod +x cfssljson_linux-amd64
sudo mv cfssljson_linux-amd64 /usr/local/bin/cfssljson

echo '{
  "signing": {
    "default": {
      "expiry": "8760h"
    },
    "profiles": {
      "kubernetes": {
        "usages": ["signing", "key encipherment", "server auth", "client auth"],
        "expiry": "8760h"
      }
    }
  }
}' > ca-config.json


echo '{
  "CN": "Kubernetes",
  "key": {
    "algo": "rsa",
    "size": 2048
  },
  "names": [
    {
      "C": "US",
      "L": "Portland",
      "O": "Kubernetes",
      "OU": "CA",
      "ST": "Oregon"
    }
  ]
}' > ca-csr.json


cfssl gencert -initca ca-csr.json | cfssljson -bare ca


cat > kubernetes-csr.json <<EOF
{
  "CN": "kubernetes",
  "hosts": [
    "$hostIP",
    "$hostname",
    "10.32.0.1",
    "127.0.0.1"
  ],
  "key": {
    "algo": "rsa",
    "size": 2048
  },
  "names": [
    {
      "C": "US",
      "L": "Portland",
      "O": "Kubernetes",
      "OU": "Cluster",
      "ST": "Oregon"
    }
  ]
}
EOF

cfssl gencert \
  -ca=ca.pem \
  -ca-key=ca-key.pem \
  -config=ca-config.json \
  -profile=kubernetes \
  kubernetes-csr.json | cfssljson -bare kubernetes

## ETCD
sudo mkdir -p /etc/etcd/
sudo cp ca.pem kubernetes-key.pem kubernetes.pem /etc/etcd/

wget https://github.com/coreos/etcd/releases/download/"$etcdVersion"/etcd-"$etcdVersion"-linux-amd64.tar.gz
tar -xvf etcd-"$etcdVersion"-linux-amd64.tar.gz
sudo mv etcd-"$etcdVersion"-linux-amd64/etcd* /usr/bin/

sudo mkdir -p /var/lib/etcd

cat > etcd.service <<EOF
[Unit]
Description=etcd
Documentation=https://github.com/coreos

[Service]
ExecStart=/usr/bin/etcd --name etcd0 \
  --cert-file=/etc/etcd/kubernetes.pem \
  --key-file=/etc/etcd/kubernetes-key.pem \
  --peer-cert-file=/etc/etcd/kubernetes.pem \
  --peer-key-file=/etc/etcd/kubernetes-key.pem \
  --trusted-ca-file=/etc/etcd/ca.pem \
  --peer-trusted-ca-file=/etc/etcd/ca.pem \
  --initial-advertise-peer-urls https://$hostIP:2380 \
  --listen-peer-urls https://$hostIP:2380 \
  --listen-client-urls https://$hostIP:2379,http://127.0.0.1:2379 \
  --advertise-client-urls https://$hostIP:2379 \
  --initial-cluster-token etcd-cluster-0 \
  --initial-cluster etcd0=https://$hostIP:2380 \
  --initial-cluster-state new \
  --data-dir=/var/lib/etcd
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

sudo mv etcd.service /etc/systemd/system/

sudo systemctl daemon-reload
sudo systemctl enable etcd
sudo systemctl start etcd

sleep 3
etcdctl --ca-file=/etc/etcd/ca.pem cluster-health


## K8 Master
sudo mkdir -p /var/lib/kubernetes
sudo cp ca.pem kubernetes-key.pem kubernetes.pem ca-key.pem /var/lib/kubernetes/

wget https://storage.googleapis.com/kubernetes-release/release/"$k8sVersion"/bin/linux/amd64/kube-apiserver
wget https://storage.googleapis.com/kubernetes-release/release/"$k8sVersion"/bin/linux/amd64/kube-controller-manager
wget https://storage.googleapis.com/kubernetes-release/release/"$k8sVersion"/bin/linux/amd64/kube-scheduler
wget https://storage.googleapis.com/kubernetes-release/release/"$k8sVersion"/bin/linux/amd64/kubectl


chmod +x kube-apiserver kube-controller-manager kube-scheduler kubectl
sudo mv kube-apiserver kube-controller-manager kube-scheduler kubectl /usr/bin/

cat > token.csv <<EOF
$adminToken,admin,admin
EOF
sudo mv token.csv /var/lib/kubernetes

cat > kube-apiserver.service <<EOF
[Unit]
Description=Kubernetes API Server
Documentation=https://github.com/GoogleCloudPlatform/kubernetes

[Service]
ExecStart=/usr/bin/kube-apiserver \
  --admission-control=NamespaceLifecycle,LimitRanger,SecurityContextDeny,ServiceAccount,ResourceQuota \
  --advertise-address=$hostIP \
  --allow-privileged=true \
  --apiserver-count=1 \
  --authorization-mode=RBAC \
  --bind-address=0.0.0.0 \
  --enable-swagger-ui=true \
  --etcd-cafile=/var/lib/kubernetes/ca.pem \
  --insecure-bind-address=127.0.0.1 \
  --kubelet-certificate-authority=/var/lib/kubernetes/ca.pem \
  --etcd-servers=https://$hostIP:2379 \
  --service-account-key-file=/var/lib/kubernetes/kubernetes-key.pem \
  --service-cluster-ip-range=10.32.0.0/16 \
  --service-node-port-range=30000-32767 \
  --tls-cert-file=/var/lib/kubernetes/kubernetes.pem \
  --tls-private-key-file=/var/lib/kubernetes/kubernetes-key.pem \
  --token-auth-file=/var/lib/kubernetes/token.csv \
  --v=2
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

sudo mv kube-apiserver.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable kube-apiserver
sudo systemctl start kube-apiserver

cat > kube-controller-manager.service <<EOF
[Unit]
Description=Kubernetes Controller Manager
Documentation=https://github.com/GoogleCloudPlatform/kubernetes

[Service]
ExecStart=/usr/bin/kube-controller-manager \
  --cluster-name=kubernetes \
  --leader-elect=true \
  --master=http://127.0.0.1:8080 \
  --root-ca-file=/var/lib/kubernetes/ca.pem \
  --service-cluster-ip-range=10.32.0.0/16 \
  --pod-eviction-timeout 30s \
  --service-account-private-key-file=/var/lib/kubernetes/ca-key.pem \
  --cluster-name=kubernetes \
  --cluster-signing-cert-file=/var/lib/kubernetes/ca.pem \
  --cluster-signing-key-file=/var/lib/kubernetes/ca-key.pem \
  --service-cluster-ip-range=10.32.0.0/16 \
  --v=2
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

sudo mv kube-controller-manager.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable kube-controller-manager
sudo systemctl start kube-controller-manager

cat > kube-scheduler.service <<EOF
[Unit]
Description=Kubernetes Scheduler
Documentation=https://github.com/GoogleCloudPlatform/kubernetes

[Service]
ExecStart=/usr/bin/kube-scheduler \
  --leader-elect=true \
  --master=http://127.0.0.1:8080 \
  --v=2
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

sudo mv kube-scheduler.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable kube-scheduler
sudo systemctl start kube-scheduler

sleep 3
kubectl get cs


## Worker
wget https://get.docker.com/builds/Linux/x86_64/docker-"$dockerVersion".tgz
tar -xvf docker-"$dockerVersion".tgz
sudo cp docker/docker* /usr/bin/

cat > docker.service <<EOF
[Unit]
Description=Docker Application Container Engine
Documentation=http://docs.docker.io

[Service]
ExecStart=/usr/bin/docker daemon \
  --iptables=false \
  --ip-masq=false \
  --host=unix:///var/run/docker.sock \
  --log-level=error \
  --storage-driver=overlay2
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

sudo mv docker.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable docker
sudo systemctl start docker
sleep 2
sudo docker version

sudo mkdir -p /etc/cni/net.d
wget https://github.com/containernetworking/cni/releases/download/"$cniVersion"/cni-amd64-"$cniVersion".tgz
sudo tar -xvf cni-amd64-"$cniVersion".tgz -C /etc/cni/net.d

cat >  10-calico.conf <<EOF
{
    "name": "calico-k8s-network",
    "type": "calico",
    "etcd_endpoints": "http://127.0.0.1:2379",
    "etcd_ca_cert_file": "/var/lib/kubernetes/ca.pem",
    "ipam": {
        "type": "calico-ipam",
        "assign_ipv4": "true",
        "assign_ipv6": "false"

    },
    "policy": {
        "type": "k8s"
    },
    "kubernetes": {
        "kubeconfig": "/var/lib/kubelet/kubeconfig"
    }
}

EOF

sudo mv 10-calico.conf /etc/cni/net.d/

cat > calico.service  <<EOF
[Unit]
Description=calico node
After=docker.service
Requires=docker.service

[Service]
User=root
PermissionsStartOnly=true
Environment=ETCD_ENDPOINTS=http://127.0.0.1:2379
Environment=ETCD_CA_CERT_FILE=/var/lib/kubernetes/ca.pem
ExecStart=/usr/bin/docker run --net=host --privileged --name=calico-node --rm -e CALICO_NETWORKING_BACKEND=bird  \
	-e CALICO_LIBNETWORK_ENABLED=true -e CALICO_LIBNETWORK_IFPREFIX=cali  \
	-e ETCD_AUTHORITY= -e ETCD_SCHEME= -e ETCD_CA_CERT_FILE=/etc/calico/certs/ca_cert.crt \
	-e IP=$hostIP \
        -e NO_DEFAULT_POOLS= -e CALICO_LIBNETWORK_ENABLED=true  \
	-e ETCD_ENDPOINTS=http://127.0.0.1:2379  \
	-v /var/lib/kubernetes/ca.pem:/etc/calico/certs/ca_cert.crt  \
	-e NODENAME=$hostname -e CALICO_NETWORKING_BACKEND=bird  \
	-v /var/run/calico:/var/run/calico -v /lib/modules:/lib/modules -v /var/log/calico:/var/log/calico  \
	-v /run/docker/plugins:/run/docker/plugins -v /var/run/docker.sock:/var/run/docker.sock  \
	calico/node:latest
ExecStop=/usr/bin/docker rm -f calico-node
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target

EOF

sudo mv calico.service /etc/systemd/system/

sudo systemctl daemon-reload
sudo systemctl enable calico
sudo systemctl start calico

wget https://github.com/projectcalico/calicoctl/releases/download/$calicoctlVersion/calicoctl
chmod +x calicoctl
sudo mv calicoctl /usr/local/bin

wget https://github.com/projectcalico/cni-plugin/releases/download/$calicoCniVersion/calico
wget https://github.com/projectcalico/cni-plugin/releases/download/$calicoCniVersion/calico-ipam
chmod +x calico calico-ipam
sudo mv calico /etc/cni/net.d
sudo mv calico-ipam /etc/cni/net.d

wget https://storage.googleapis.com/kubernetes-release/release/$k8sVersion/bin/linux/amd64/kubelet
wget https://storage.googleapis.com/kubernetes-release/release/$k8sVersion/bin/linux/amd64/kube-proxy

wget https://storage.googleapis.com/kubernetes-helm/helm-$helmVersion-linux-amd64.tar.gz
tar -zxvf helm-$helmVersion-amd64.tar.gz
mv linux-amd64/helm /usr/local/bin

chmod +x  kube-proxy kubelet
sudo mv kube-proxy kubelet /usr/bin/
sudo mkdir -p /var/lib/kubelet/

cat > kubeconfig  <<EOF
apiVersion: v1
kind: Config
clusters:
- cluster:
    certificate-authority: /var/lib/kubernetes/ca.pem
    server: http://127.0.0.1:8080
  name: kubernetes
contexts:
- context:
    cluster: kubernetes
    user: kubelet
  name: kubelet
current-context: kubelet
users:
- name: kubelet
  user:
    token: $kubeletToken
EOF

sudo mv kubeconfig /var/lib/kubelet/

cat > kubelet.service  <<EOF
[Unit]
Description=Kubernetes Kubelet
Documentation=https://github.com/GoogleCloudPlatform/kubernetes
After=docker.service
Requires=docker.service

[Service]
ExecStart=/usr/bin/kubelet \
  --allow-privileged=true \
  --cloud-provider= \
  --cluster-dns=10.32.0.10 \
  --cluster-domain=cluster.local \
  --container-runtime=docker \
  --docker=unix:///var/run/docker.sock \
  --network-plugin=cni \
  --network-plugin-dir=/etc/cni/net.d \
  --kubeconfig=/var/lib/kubelet/kubeconfig \
  --serialize-image-pulls=false \
  --tls-cert-file=/var/lib/kubernetes/kubernetes.pem \
  --tls-private-key-file=/var/lib/kubernetes/kubernetes-key.pem \
  --api-servers=http://127.0.0.1:8080 \
  --v=2

Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

sudo mv kubelet.service /etc/systemd/system/

sudo systemctl daemon-reload
sudo systemctl enable kubelet
sudo systemctl start kubelet

cat > kube-proxy.service  <<EOF
[Unit]
Description=Kubernetes Kube Proxy
Documentation=https://github.com/GoogleCloudPlatform/kubernetes

[Service]
ExecStart=/usr/bin/kube-proxy \
  --master=http://127.0.0.1:8080 \
  --kubeconfig=/var/lib/kubelet/kubeconfig \
  --proxy-mode=iptables \
  --v=2

Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

sudo mv kube-proxy.service /etc/systemd/system/

sudo systemctl daemon-reload
sudo systemctl enable kube-proxy
sudo systemctl start kube-proxy

sleep 5
echo "" 
kubectl get cs ; echo "" ;  kubectl get nodes

# KubeDNS
cat <<EOF | kubectl create -f -

apiVersion: extensions/v1beta1
kind: Deployment
metadata:
  name: kube-dns
  namespace: kube-system
  labels:
    k8s-app: kube-dns
    kubernetes.io/cluster-service: "true"
spec:
  # replicas: not specified here:
  # 1. In order to make Addon Manager do not reconcile this replicas parameter.
  # 2. Default is 1.
  # 3. Will be tuned in real time if DNS horizontal auto-scaling is turned on.
  strategy:
    rollingUpdate:
      maxSurge: 10%
      maxUnavailable: 0
  selector:
    matchLabels:
      k8s-app: kube-dns
  template:
    metadata:
      labels:
        k8s-app: kube-dns
      annotations:
        scheduler.alpha.kubernetes.io/critical-pod: ''
        scheduler.alpha.kubernetes.io/tolerations: '[{"key":"CriticalAddonsOnly", "operator":"Exists"}]'
    spec:
      containers:
      - name: kubedns
        image: gcr.io/google_containers/kubedns-amd64:1.9
        resources:
          # TODO: Set memory limits when we've profiled the container for large
          # clusters, then set request = limit to keep this container in
          # guaranteed class. Currently, this container falls into the
          # "burstable" category so the kubelet doesn't backoff from restarting it.
          limits:
            memory: 170Mi
          requests:
            cpu: 100m
            memory: 70Mi
        livenessProbe:
          httpGet:
            path: /healthz-kubedns
            port: 8080
            scheme: HTTP
          initialDelaySeconds: 60
          timeoutSeconds: 5
          successThreshold: 1
          failureThreshold: 5
        readinessProbe:
          httpGet:
            path: /readiness
            port: 8081
            scheme: HTTP
          # we poll on pod startup for the Kubernetes master service and
          # only setup the /readiness HTTP server once that's available.
          initialDelaySeconds: 3
          timeoutSeconds: 5
        args:
        - --domain=$clusterDomain
        - --dns-port=10053
        - --config-map=kube-dns
        # This should be set to v=2 only after the new image (cut from 1.5) has
        # been released, otherwise we will flood the logs.
        - --v=0
        env:
        - name: PROMETHEUS_PORT
          value: "10055"
        ports:
        - containerPort: 10053
          name: dns-local
          protocol: UDP
        - containerPort: 10053
          name: dns-tcp-local
          protocol: TCP
        - containerPort: 10055
          name: metrics
          protocol: TCP
      - name: dnsmasq
        image: gcr.io/google_containers/kube-dnsmasq-amd64:1.4
        livenessProbe:
          httpGet:
            path: /healthz-dnsmasq
            port: 8080
            scheme: HTTP
          initialDelaySeconds: 60
          timeoutSeconds: 5
          successThreshold: 1
          failureThreshold: 5
        args:
        - --cache-size=1000
        - --no-resolv
        - --server=127.0.0.1#10053
        - --log-facility=-
        ports:
        - containerPort: 53
          name: dns
          protocol: UDP
        - containerPort: 53
          name: dns-tcp
          protocol: TCP
        # see: https://github.com/kubernetes/kubernetes/issues/29055 for details
        resources:
          requests:
            cpu: 150m
            memory: 10Mi
      - name: dnsmasq-metrics
        image: gcr.io/google_containers/dnsmasq-metrics-amd64:1.0
        livenessProbe:
          httpGet:
            path: /metrics
            port: 10054
            scheme: HTTP
          initialDelaySeconds: 60
          timeoutSeconds: 5
          successThreshold: 1
          failureThreshold: 5
        args:
        - --v=2
        - --logtostderr
        ports:
        - containerPort: 10054
          name: metrics
          protocol: TCP
        resources:
          requests:
            memory: 10Mi
      - name: healthz
        image: gcr.io/google_containers/exechealthz-amd64:1.2
        resources:
          limits:
            memory: 50Mi
          requests:
            cpu: 10m
            # Note that this container shouldn't really need 50Mi of memory. The
            # limits are set higher than expected pending investigation on #29688.
            # The extra memory was stolen from the kubedns container to keep the
            # net memory requested by the pod constant.
            memory: 50Mi
        args:
        - --cmd=nslookup kubernetes.default 127.0.0.1 >/dev/null
        - --url=/healthz-dnsmasq
        - --cmd=nslookup kubernetes.default 127.0.0.1:10053 >/dev/null
        - --url=/healthz-kubedns
        - --port=8080
        - --quiet
        ports:
        - containerPort: 8080
          protocol: TCP
      dnsPolicy: Default  # Don't use cluster DNS.
---

apiVersion: v1
kind: Service
metadata:
  name: kube-dns
  namespace: kube-system
  labels:
    k8s-app: kube-dns
    kubernetes.io/cluster-service: "true"
    kubernetes.io/name: "KubeDNS"
spec:
  selector:
    k8s-app: kube-dns
  clusterIP: 10.32.0.10
  ports:
    - name: dns
      port: 53
      protocol: UDP
    - name: dns-tcp
      port: 53
      protocol: TCP

EOF


# Calico
cat <<EOF | kubectl create -f -

# Create this manifest using kubectl to deploy
# the Calico policy controller on Kubernetes.
# It deploys a single instance of the policy controller.
apiVersion: extensions/v1beta1
kind: Deployment
metadata:
  name: calico-policy-controller
  namespace: kube-system
  labels:
    k8s-app: calico-policy
spec:
  # Only a single instance of the policy controller should be
  # active at a time.  Since this pod is run as a Deployment,
  # Kubernetes will ensure the pod is recreated in case of failure,
  # removing the need for passive backups.
  replicas: 1
  strategy:
    type: Recreate
  template:
    metadata:
      name: calico-policy-controller
      namespace: kube-system
      labels:
        k8s-app: calico-policy
    spec:
      hostNetwork: true
      containers:
        - name: calico-policy-controller
          # Make sure to pin this to your desired version.
          image: calico/kube-policy-controller:v0.7.0
          env:
            # Configure the policy controller with the location of
            # your etcd cluster.
            - name: ETCD_ENDPOINTS
              value: "http://127.0.0.1:2379"
            # Location of the Kubernetes API - this shouldn't need to be
            # changed so long as it is used in conjunction with
            # CONFIGURE_ETC_HOSTS="true".
            - name: K8S_API
              value: "https://10.32.0.1:443"
            # Configure /etc/hosts within the container to resolve
            # the kubernetes.default Service to the correct clusterIP
            # using the environment provided by the kubelet.
            # This removes the need for KubeDNS to resolve the Service.
            - name: CONFIGURE_ETC_HOSTS
              value: "false"
---
kind: ClusterRole
apiVersion: rbac.authorization.k8s.io/v1beta1
metadata:
  name: calico-policy-controller
  namespace: kube-system
rules:
  - apiGroups:
    - ""
    - extensions
    resources:
      - pods
      - namespaces
      - networkpolicies
    verbs:
      - watch
      - list
---
kind: ClusterRoleBinding
apiVersion: rbac.authorization.k8s.io/v1beta1
metadata:
  name: calico-policy-controller
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: calico-policy-controller
subjects:
- kind: ServiceAccount
  name: calico-policy-controller
  namespace: kube-system
---
kind: ClusterRole
apiVersion: rbac.authorization.k8s.io/v1beta1
metadata:
  name: calico-node
  namespace: kube-system
rules:
  - apiGroups: [""]
    resources:
      - pods
      - nodes
    verbs:
      - get
---
apiVersion: rbac.authorization.k8s.io/v1beta1
kind: ClusterRoleBinding
metadata:
  name: calico-node
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: calico-node
subjects:
- kind: ServiceAccount
  name: calico-node
  namespace: kube-system

EOF

# KubeDashboard
kubectl create -f https://git.io/kube-dashboard  

# Init HELM
helm init
