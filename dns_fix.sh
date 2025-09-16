#!/bin/bash
# Script to fix an issue where pods and VMs inside a VPC cannot resolve DNS
SSH_USER="root"
SSH_HOST="router"
DNS_FIX="echo net.ipv4.tcp_l3mdev_accept=1 >> /etc/sysctl.d/kubernetes.conf
echo net.ipv4.udp_l3mdev_accept=1 >> /etc/sysctl.d/kubernetes.conf
sysctl --system
iptables-save > /etc/systemd/scripts/ip4save
systemctl restart iptables"

# Execute the command on the remote server
ssh "$SSH_USER@$SSH_HOST" "$DNS_FIX"

# Optional: Add error handling or further actions
if [ $? -eq 0 ]; then
    echo "Command executed successfully on $SSH_HOST."
else
    echo "Error executing command on $SSH_HOST."
fi