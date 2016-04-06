#!/bin/bash

#-------------------------------------------------------------------------------
#   Copyright 2016 Dave Costakos <david.costakos@redhat.com>
#
#   Licensed under the Apache License, Version 2.0 (the "License");
#   you may not use this file except in compliance with the License.
#   You may obtain a copy of the License at
#
#       http://www.apache.org/licenses/LICENSE-2.0
#
#   Unless required by applicable law or agreed to in writing, software
#   distributed under the License is distributed on an "AS IS" BASIS,
#   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
#   See the License for the specific language governing permissions and
#   limitations under the License.
#-------------------------------------------------------------------------------
# File: install_undercloud_vm.sh
# Author: Dave Costakos <david.costakos@redhat.com>
# Description: Script to install undercloud as a VM on a physical machine
# Note: Presumed that a public brige for routable networking traffic and a private bridge for OverCloud provisioning 
#       are already setup on the physical host
#
# Example: sudo ./install_osp_director_vm.sh --reg-username RHN_Username --reg-password RHN_Password --reg-pool RHN_Subscription_Pool --rootpw redhat321 --public-bridge br-public --private-bridge br-prov --prov-network-cidr 192.0.2 --vm-hostname rhel-osp-director.localdomain

set_args()  {
  while [ "$1" != "" ]; do
    echo "Checking $1:"
    case $1 in
      "--reg-local")
        reg=true
        ;;
      "--reg-username")
        shift
        reg_username=$1
        echo "Set reg_username to $1"
        ;;
      "--reg-password")
        shift
        reg_password=$1
        echo "Set reg_password to $1"
        ;;
      "--rootpw")
        shift
        rootpw=$1
        ;;
      "--public-bridge")
        shift
        public_bridge=$1
        ;;
      "--private-bridge")
        shift
        private_bridge=$1
        ;;
      "--vm-hostname")
        shift
        vm_hostname=$1
        ;;
      "--prov-network-cidr")
        shift
        prov_network_cidr=$1
        ;;
      "--ram")
        shift
        ram=$1
        ;;
      "--vcpus")
        shift
        vcpus=$1
        ;;
    esac
    shift
  done
}

reg=""
reg_username=""
reg_password=""
reg_pool=""
rootpw=""
public_bridge="br-public"
private_bridge="br-prov"
vm_hostname="rhel-osp-director.localdomain"
prov_network="192.0.2"
# suitable numbers for my laptop but not for a 'real' deployment
ram=16384
vcpus=4
set_args $*

if [ "${reg_password}x" == "x" ] ; then
  read -s -p "Enter your RHN Password: " reg_password
fi

if [ "${rootpw}x" == "x" ] ; then
  read -s -p "Enter OSP Director Root/Stack Password: " rootpw
fi

#yum -y install rhel-guest-image-7
BASEFILE=$(ls /usr/share/rhel-guest-image-7/*.qcow2 | head -n 1)

if [ -z "${BASEFILE}" ] ; then
  echo "No rhel-guest-image-7 RPM in /usr/share/rhel-guest-image-7"
  exit 5
fi

IMG_FILE="/var/lib/libvirt/images/$vm_hostname.qcow2"
cp ${BASEFILE} ${IMG_FILE}
chown qemu:kvm ${IMG_FILE}
qemu-img resize ${IMG_FILE} +100G

cat << EOF > meta-data
instance-id: $vm_hostname
local-hostname: $vm_hostname
EOF
cat << EOF > user-data
#cloud-config
hostname: $vm_hostname
fqdn: $vm_hostname
debug: True
ssh_pwauth: True
disable_root: false
users:
  - name: stack
    sudo: ['ALL=(ALL) NOPASSWD:ALL']
write_files:
  - content: |
      #!/bin/bash
      #
      echo "Installing Undercloud as \${USER}"
      set -o verbose
      pushd /home/stack
      cp /usr/share/instack-undercloud/undercloud.conf.sample /home/stack/undercloud.conf
      sed -i s/#discovery_runbench = false/discovery_runbench = true/g /home/stackundercloud.conf
      sed -i s/^#local_ip/local_ip/g /home/stack/undercloud.conf
      sed -i s/^#network_cidr/network_cidr/g /home/stack/undercloud.conf
      sed -i s/^#undercloud_public_vip/undercloud_public_vip/g /home/stack/undercloud.conf
      sed -i s/^#undercloud_admin_vip/undercloud_admin_vip/g /home/stack/undercloud.conf
      sed -i s/^#masquerade_network/masquerade_network/g /home/stack/undercloud.conf
      sed -i s/^#dhcp_start/dhcp_start/g /home/stack/undercloud.conf
      sed -i s/^#dhcp_end/dhcp_end/g /home/stack/undercloud.conf
      sed -i s/^#network_cider/network_cider/g /home/stack/undercloud.conf
      sed -i s/^#network_gateway/network_gateway/g /home/stack/undercloud.conf
      sed -i s/^#discovery_iprange/discovery_iprange/g /home/stack/undercloud.conf
      sed -s 's/192\.0\.2/$prov_network/g' /home/stack/undercloud.conf
      mkdir templates images
      echo "Undercloud Configuration File:"
      cat undercloud.conf
      openstack undercloud install
    path: /install_undercloud.sh
    permissions: '0755'
chpasswd:
  list: |
    root:$rootpw
    stack:$rootpw
  expire: False
runcmd:
  - subscription-manager register --username=$reg_username --password=$reg_password
  - subscription-manager attach --pool=$reg_pool
  - subscription-manager repos --disable=*
  - subscription-manager repos --enable=rhel-7-server-rpms --enable=rhel-7-server-extras-rpms --enable=rhel-7-server-openstack-7.0-rpms --enable=rhel-7-server-openstack-7.0-director-rpms --enable rhel-7-server-rh-common-rpms
  - yum update -y
  - yum install -y python-rdomanager-oscplugin
  - sed -i 's/Defaults    requiretty/Defaults    !requiretty/g' /etc/sudoers
  - hostnamectl set-hostname --static $vm_hostname
  - hostnamectl set-hostname --transient $vm_hostname
  - echo 127.0.0.1 \$(hostname --fqdn) \$(hostname -s) > /etc/hosts
  - echo net.ipv4.ip_forward=1 >> /etc/sysctl.conf
  - sysctl -p /etc/sysctl.conf
  - su - stack -c /install_undercloud.sh
  - subscription-manager unregister
  - echo "DONE, Now Rebooting"
  - reboot -f
EOF
genisoimage --output /var/lib/libvirt/images/cloud-init.iso -volid cidata -joliet -rock user-data meta-data
chown qemu:kvm /var/lib/libvirt/images/cloud-init.iso
virt-install --name $vm_hostname --ram $ram --vcpus $vcpus --disk /var/lib/libvirt/images/$vm_hostname.qcow2,format=qcow2,bus=virtio --disk /var/lib/libvirt/images/cloud-init.iso,device=cdrom --network bridge=$public_bridge --network bridge=$private_bridge --graphics none --noreboot
virsh start $vm_hostname
virsh attach-disk $vm_hostname  '' hda --type cdrom --mode readonly
virsh snapshot-create $vm_hostname undercloud-clean


