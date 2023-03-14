#!/bin/bash

# If user is empty, use cloud
user=$USER
if [ -z "$user" ]; then
    user=cloud
fi

# If password is empty, use cloud
password=$PASSWORD
if [ -z "$password" ]; then
    password=cloud
fi

# Get host hostname
hostname=$(hostname)

# If gateway is not set, use the gateway of eth0
if [ -z "$gateway" ]; then
    gateway=$(ip route show | grep default | awk '{print $3}')
    gateway=$(echo $gateway | awk -F. '{print $1"."$2"."$3"."$4}')
fi

# If ip is not set, use the ip of eth0
ip=$IP
if [ -z "$ip" ]; then
    ip=$(ip addr show eth0 | grep "inet " | awk '{print $2}' | cut -d/ -f1)
    ip=$(echo $ip | awk -F. '{print $1"."$2"."$3"."$4}')
fi

# Create bridge interface
ip link add name br0 type bridge
ip tuntap add dev tap0 mode tap user root
ip link set dev tap0 master br0
ip link set dev eth0 master br0
ip link set br0 up
# Remove ip from eth0 and add it to br0
ip addr del $ip/16 dev eth0
ip addr add $ip/16 dev br0
# Add new default route
ip route add default via $gateway dev br0
ip link set tap0 up

ssh_key=""

if [ ! -z "$SSH_KEY" ]; then
cat <<EOF > /tmp/ssh_key
  ssh_authorized_keys:
  - $SSH_KEY
EOF
ssh_key=`cat /tmp/ssh_key`
cat /tmp/ssh_key
fi

delete_ssh_key=$DELETE_SSH_KEY
if [ -z "$delete_ssh_key" ]; then
    delete_ssh_key="true"
fi

## Generate cloud-init config
cat <<EOF > /tmp/user-data
#cloud-config

version: 2
hostname: $hostname
manage_etc_hosts: true
users:
- default
- name: $user
  primary_group: $user
  sudo: ALL=(ALL) NOPASSWD:ALL
  groups: users, admin, sudoers
  homedir: /home/$user
  shell: /bin/bash
  lock_passwd: false
$ssh_key

ssh_pwauth: true
disable_root: true
chpasswd:
  expire: false
  users:
    - name: $user
      password: $password
      type: text

ssh_deletekeys: $delete_ssh_key

runcmd:
  - netplan apply
  - sh -c "sleep 10 && cloud-init clean" &

final_message: "The system is finally up, after \$UPTIME seconds"
EOF

from_network=$FROM_NETWORK
if [ -z "$from_network" ]; then
    from_network=ens3
fi

to_network=$TO_NETWORK
if [ -z "$to_network" ]; then
    to_network=eth0
fi

# Generate network config
cat <<EOF > /tmp/network-config
#cloud-config

network:
  version: 2
  renderer: networkd
  ethernets:
    $from_network:
      match:
        name: $from_network
      set-name: $to_network
      dhcp4: no
      addresses: [$ip/16]
      routes:
      - to: default
        via: $gateway
      nameservers:
          search: [Local]
          addresses: [8.8.8.8, 8.8.4.4]
EOF

# Generate seed
/usr/bin/cloud-localds /tmp/seed.img /tmp/user-data -N /tmp/network-config

# Start quemu with tap0
/usr/bin/qemu-system-x86_64 -net nic,model=virtio -net tap,ifname=tap0,script=no,downscript=no -cdrom /tmp/seed.img --no-graphic $@
