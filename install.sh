# Fedora Magazine
# https://fedoramagazine.org/kubernetes-with-cri-o-on-fedora-linux-39/

################################################################################
###                         1. Preparing the cluster nodes                   ###
################################################################################

####################
## Kernel modules ##
####################

# Kubernetes, in its standard configuration, requires the following kernel 
# modules and configuration values for bridging network traffic, overlaying 
# filesystems, and forwarding network packets. An adequate size for user and pid 
# namespaces for userspace containers is also provided in the below configuration
# example.

sudo cat <<EOF | sudo tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF

sudo systemctl restart systemd-modules-load.service

cat <<EOF | sudo tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
user.max_pid_namespaces             = 1048576
user.max_user_namespaces            = 1048576
EOF

sudo sysctl --system


######################
## Installing CRI-O ##
######################

# Container Runtime Interface OCI is an opensource container engine dedicated to 
# Kubernetes. The engine implements the Kubernetes grpc protocol (CRI) and is 
# compatible with any low-level OCI container runtime. All supported runtimes must be 
# installed separately on the host. It is important to note that CRI-O is 
# version-locked with Kubernetes. We will deploy cri-o:1.27 with kubernetes:1.27 on 
# fedora-39.

sudo dnf install -y cri-o cri-tools 

# To check what the package installed:

sudo rpm -qRc cri-o

# Notice it uses conmon for monitoring and container-selinux policies. Also, the main 
# configuration file is crio.conf and it added some default networking plugins to 
# /etc/cni. For networking, this guide will not rely on the default CRI-O plugins; 
# though it is possible to use them.

sudo rm -rf /etc/cni/net.d/*  

# Besides the above configuration files, CRI-O uses the same image and storage libraries 
# as Podman. So you can use the same configuration files for registries and signature 
# verification policies as you would when using Podman. 
# See the CRI-O README for examples.


################
## Cgroups v2 ##
################

# Recent versions of Fedora Linux have cgroups v2 enabled by default. Cgroups v2 brings
# better control over memory and CPU resource management. With cgroups v1, a pod would 
# receive a kill signal when a container exceeds the memory limit. With cgroups v2, 
# memory allocation is “throttled” by systemd. See the cgroupfsv2 docs for more details 
# about the changes.

sudo stat -f /sys/fs/cgroup/


#########################
## Additional runtimes ##
#########################

# In Fedora Linux, systemd is both the init system and the default cgroups driver/manager. 
# While checking crio.conf we notice this version already uses systemd. If no other 
# cgroups driver is explicitly passed to kubeadm, then kubelet will also use systemd by 
# default in version 1.27. We will set systemd explicitly, nonetheless, and change the 
# default runtime to crun which is faster and has a smaller memory footprint. We will 
# also define each new runtime block as shown below. We will use configuration drop-in 
# files and make sure the files are labeled with the proper selinux context.

sudo dnf install -y crun

sudo sed -i 's/# cgroup_manager/cgroup_manager/g' /etc/crio/crio.conf
sudo sed -i 's/# default_runtime = "runc"/default_runtime = "crun"/g' /etc/crio/crio.conf

sudo mkdir /etc/crio/crio.conf.d

sudo tee -a /etc/crio/crio.conf.d/90-crun <<CRUN 
[crio.runtime.runtimes.crun]
runtime_path = "/usr/bin/crun"
runtime_type = "oci"
CRUN

echo "containers:1000000:1048576" | sudo tee -a /etc/subuid
echo "containers:1000000:1048576" | sudo tee -a /etc/subgid

sudo tee -a /etc/crio/crio.conf.d/91-userns <<USERNS 
[crio.runtime.workloads.userns]
activation_annotation = "io.kubernetes.cri-o.userns-mode"
allowed_annotations = ["io.kubernetes.cri-o.userns-mode"]
USERNS

sudo chcon -R --reference=/etc/crio/crio.conf  /etc/crio/crio.conf.d/ 

sudo ls -laZ /etc/crio/crio.conf.d/

# crio.conf respects the TOML format and is easily managed and maintained. 
# The help/man pages are also detailed. After you change the configuration, enable the 
# service.

sudo systemctl daemon-reload
sudo systemctl enable crio --now 


##################
## Disable swap ##
##################

# The latest Fedora Linux versions enable swap-on-zram by default. zram creates an 
# emulated device that uses RAM as storage and compresses memory pages. It is faster 
# than traditional disk partitions. You can use zramctl to inspect and configure your 
# zram device(s). However, the device’s initialization and mounting are performed by 
# systemd on system startup as configured in the zram-generator.conf file.

sudo swapoff -a
sudo zramctl --reset /dev/zram0
sudo dnf -y remove zram-generator-defaults


####################
## Firewall rules ##
####################

# Keep the firewall enabled and open only the necessary ports in accordance with the 
# official docs. We have a set of rules for the Control Planes nodes.

sudo firewall-cmd --set-default-zone=internal
sudo firewall-cmd --permanent  \
  --add-port=10250/tcp \
  --add-port=30000-32767/tcp 
sudo firewall-cmd --reload

# Please note we did not discuss network topology. In such discussions, control plane 
# nodes and worker nodes are on different subnets. Each subnet has an interface that 
# connects all hosts. VMs could have multiple interfaces and/or the administrator might 
# want to associate a specific interface with a specific zone and open ports on that #
# interface. In such cases you will explicitly provide the zone argument to the above 
# commands.



#####################
## The DNS service ##
#####################

# Fedora Linux 39 comes with systemd-resolved configured as its DNS resolver. In this 
# configuration the user has access to a local stub file that contains a 127.0.0.53 
# entry that directs local DNS clients to systemd-resolved.

# lrwxrwxrwx. 1 root root 39 Sep 11  2022 /etc/resolv.conf -> ../run/systemd/resolve/stub-resolv.conf

# The reference to 127.0.0.53 triggers a coredns loop plugin error in Kubernetes. 
# A list of next-hop DNS servers is maintained by systemd in /run/systemd/resolve/resolv.conf. 
# According to the systemd-resolved man page, the /etc/resolv.conf file can be symlinked to 
# /run/systemd/resolve/resolv.conf so that local DNS clients will bypass systemd-resolved 
# and talk directly to the DNS servers. For some DNS clients, however, bypassing 
# systemd-resolved might not be desirable.

# A better approach is to configure kubelet to use the resolv.conf file. Configuring 
# kubelet to reference the alternate resolv.conf will be demonstrated in the following 
# sections.


#########################
## Kubernetes packages ##
#########################

# We will use kubeadm that is a mature package to easily and quickly install 
# production-grade Kubernetes.

sudo dnf install -y kubernetes-kubeadm kubernetes-client

# kubernetes-kubeadm generates a kubelet drop-in file at 
# /etc/systemd/system/kubelet.service.d/kubeadm.conf. This file can be used to 
# configure instance-specific kubelet configurations. However, the recommended approach 
# is to use kubeadm configuration files. 
# For example, kubeadm creates /var/lib/kubelet/kubeadm-flags.env that is referenced by 
# the above mentioned kubelet drop-in file.

# The kubelet will be started automatically by kubeadm. For now we will enable it so it 
# persists across restarts.

sudo systemctl enable kubelet



######################################################################################
###                          2. Initialize the Control Plane                       ###
######################################################################################

# For the installation, we pass some cluster wide configuration to kubeadm like
#  pod and service CIDRs. For more details refer to kubeadm configuration docs 
# and kubelet config docs.

cd ~

cat <<CONFIG > kubeadmin-config.yaml
---
apiVersion: kubeadm.k8s.io/v1beta3
kind: InitConfiguration
nodeRegistration:
  name: $HOSTNAME
  criSocket: "unix:///var/run/crio/crio.sock"
  imagePullPolicy: "IfNotPresent"
  kubeletExtraArgs: 
    cgroup-driver: "systemd"
    resolv-conf: "/run/systemd/resolve/resolv.conf"
    max-pods: "4096"
    max-open-files: "20000000"
---
apiVersion: kubeadm.k8s.io/v1beta3
kind: ClusterConfiguration
kubernetesVersion: "1.27.0"
networking:
  podSubnet: "10.32.0.0/16"
  serviceSubnet: "172.16.16.0/22"
controllerManager:
  extraArgs:
    node-cidr-mask-size: "20"
    allocate-node-cidrs: "true"
---
CONFIG

# In the above configuration, we have chosen different IP subnets for pods and 
# services. This is useful when debugging. Make sure they do not overlap with 
# your node’s CIDR. To summarize the IP ranges:

#  _ services “172.16.16.0/22” – 1024 services cluster wide
#  _ pods “10.32.0.0/16” – 65536 pods cluster wide, max 4096 pods per kubelet 
#    and 20 million open files per kubelet. For other important kubelet 
#    parameters refer to kubelet config docs. Kubelet is an important component
#    running on the worker nodes so make sure you read the config docs carefully.

# kube-controller-manager has a component called nodeipam that splits the 
# podcidr into smaller ranges and allocates these ranges to each node via the 
# (node.spec.podCIDR /node.spec.podCIDRs) properties. 
# Controller Manager property ‐‐node-cidr-mask-size defines the size of this 
# range. By default it is /24, but if you have enough resources you can make it
# larger; in our case /20. This will result in 4096 pods per node with a 
# maximum of 65536/4096=16 nodes. Adjust these properties to fit the capacity 
# of your bare-metal server.

sudo kubeadm init --skip-token-print=true --config=kubeadmin-config.yaml

mkdir -p $HOME/.kube
sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config

# There are newer networking plugins that leverage ebpf kernel capabilities or 
# ovn. However, installing such plugins requires uninstalling kube-proxy and 
# we want to maintain the deployment as standard as possible. Some of the 
# networking plugins read the kubeadm-config configmap and set up the corect 
# CIDR values without the need to read a lot of documentation.

kubectl create -f https://github.com/antrea-io/antrea/releases/download/v1.14.0/antrea.yml

# Antrea, OVN-Kubernetes are interesting CNCF projects; especially for bare-metal 
# clusters where network speed becomes a bottleneck. It also has support for 
# some high-speed Mellanox network cards. Check pods and svc health and whether a 
# correct IP address was assigned.

kubectl get pods -A -o wide
kubectl get svc -A
kubectl describe node 

# All pods should be running and healthy. Notice how the static pods and the 
# daemonsets have the same IP address as the node. CoreDNS is also reading 
# directly from the /run/systemd/resolve/resolv.conf file and not crashing.

# Generate a token for joining the worker node.

TOKEN=$(kubeadm token create --ttl=300m --print-join-command)

# The output of this command contains details for joining the worker node.
