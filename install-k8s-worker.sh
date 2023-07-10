#######################################
## Prepare the system for Kubernetes ##
#######################################

# Disable memory swap
sudo swapoff -a

# Set SELinux to permissive
sudo setenforce 0
sudo sed -i 's/^SELINUX=enforcing$/SELINUX=disabled/' /etc/selinux/config

# Forwarding IPv4 and letting iptables see bridged traffic
# n order for a Linux node's iptables to correctly view bridged traffic, verify that net.bridge.bridge-nf-call-iptables is set to 1 in your sysctl config. 
cat <<EOF | sudo tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF

sudo modprobe overlay
sudo modprobe br_netfilter

# sysctl params required by setup, params persist across reboots
cat <<EOF | sudo tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF

# Apply sysctl params without reboot
sudo sysctl --system

# Open the necessary ports used by Kubernetes Worker
sudo firewall-cmd --permanent --add-port={10248,10250,30000-32767}/tcp

# Make the changes permanent
sudo firewall-cmd --reload


##################
## Install CRIO ##
##################

export VERSION=1.25
export OS=CentOS_8
sudo curl -L -o /etc/yum.repos.d/devel:kubic:libcontainers:stable.repo https://download.opensuse.org/repositories/devel:/kubic:/libcontainers:/stable/$OS/devel:kubic:libcontainers:stable.repo
sudo curl -L -o /etc/yum.repos.d/devel:kubic:libcontainers:stable:cri-o:$VERSION.repo https://download.opensuse.org/repositories/devel:kubic:libcontainers:stable:cri-o:$VERSION/$OS/devel:kubic:libcontainers:stable:cri-o:$VERSION.repo
sudo dnf install -y crio
sudo systemctl enable crio
sudo systemctl start crio


########################
## Install Kubernetes ##
########################

#Add the Kubernetes repository to your package manager by creating the following file
cat <<EOF | sudo tee /etc/yum.repos.d/kubernetes.repo
[kubernetes]
name=Kubernetes
baseurl=https://packages.cloud.google.com/yum/repos/kubernetes-el7-x86_64
enabled=1
gpgcheck=1
repo_gpgcheck=1
gpgkey=https://packages.cloud.google.com/yum/doc/yum-key.gpg https://packages.cloud.google.com/yum/doc/rpm-package-key.gpg
exclude=kubelet kubeadm kubectl
EOF

# Upgrade dnf
sudo dnf upgrade -y

# Install all the necessary components for Kubernetes
sudo dnf install -y kubelet kubeadm kubectl --disableexcludes=kubernetes

# Start the Kubernetes services and enable them to run at startup
sudo systemctl enable kubelet
sudo systemctl start kubelet

