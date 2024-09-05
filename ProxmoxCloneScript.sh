#!/bin/bash

#  ================================================================
#  |                                                              |
#  |                  Developed by ARBR.DEV                       |
#  |              Github: https://github.com/arbrdev              |
#  |                 Web: https://www.arbr.dev                    |
#  |                                                              |
#  |            Licensed under GPL v3.0                           |
#  |  License: https://www.gnu.org/licenses/gpl-3.0.en.html       |
#  ================================================================

# Function to show script usage
function show_usage() {
  echo "Usage: $0 <vm_id> [--force-shutdown] [--snapshot]"
  exit 1
}

# Function to check node availability
function check_node_availability() {
  local NODE_IP=$1
  local NODE_NAME=$2
  
  echo -e "\033[1;36m[INFO]\033[0m Checking node availability $NODE_NAME ($NODE_IP)..."
  
  if ping -c 1 $NODE_IP &> /dev/null; then
    echo -e "\033[1;32m[INFO]\033[0m Node $NODE_NAME ($NODE_IP) is available."
  else
    echo -e "\033[1;31m[ERROR]\033[0m Node $NODE_NAME ($NODE_IP) is not available. Aborting."
    exit 1
  fi
}

# Check if the virtual machine ID was provided
if [ -z "$1" ]; then
  show_usage
fi

# Variables
VM_ID=$1
FORCE_SHUTDOWN=false
SNAPSHOT=false

# Check parameters
for arg in "$@"; do
  case $arg in
    --force-shutdown) FORCE_SHUTDOWN=true ;;
    --snapshot) SNAPSHOT=true ;;
    *) ;;
  esac
done

SOURCE_NODE_IP="<ip_source>"
DEST_NODE_IP="<ip_dest>"
SOURCE_NODE_USER="root"
DEST_NODE_USER="root"

# Check node availability
check_node_availability $SOURCE_NODE_IP "Source"
check_node_availability $DEST_NODE_IP "Destination"

echo -e "\n\n\033[1;34m===== Starting VM migration process: $VM_ID =====\033[0m\n\n"

# Check if the VM has snapshots
SNAPSHOT_COUNT=$(ssh ${SOURCE_NODE_USER}@${SOURCE_NODE_IP} "qm listsnapshot ${VM_ID} | wc -l")
if [ "$SNAPSHOT_COUNT" -gt 1 ]; then
  echo -e "\033[1;31m[ERROR]\033[0m The VM $VM_ID has snapshots. Remove the snapshots before proceeding."
  exit 1
fi

# Check the VM status
VM_STATUS=$(ssh ${SOURCE_NODE_USER}@${SOURCE_NODE_IP} "qm status ${VM_ID}" | grep -i 'status:' | awk '{print $2}')
if [ "$VM_STATUS" == "running" ] && [ "$FORCE_SHUTDOWN" = true ]; then
  echo -e "\033[1;33m[WARNING]\033[0m Shutting down VM $VM_ID..."
  ssh ${SOURCE_NODE_USER}@${SOURCE_NODE_IP} "qm shutdown ${VM_ID}"

  # Wait up to 45 seconds for the VM to shut down
  TIMEOUT=45
  INTERVAL=5
  ELAPSED=0

  while [ "$(ssh ${SOURCE_NODE_USER}@${SOURCE_NODE_IP} "qm status ${VM_ID}" | grep -i 'status:' | awk '{print $2}')" == "running" ]; do
    sleep $INTERVAL
    ELAPSED=$((ELAPSED + INTERVAL))

    if [ $ELAPSED -ge $TIMEOUT ]; then
      echo -e "\033[1;31m[ERROR]\033[0m The VM has not shut down in $TIMEOUT seconds. Forcing shutdown..."
      ssh ${SOURCE_NODE_USER}@${SOURCE_NODE_IP} "qm stop ${VM_ID}"
      
      # Wait for the VM to forcibly shut down
      while [ "$(ssh ${SOURCE_NODE_USER}@${SOURCE_NODE_IP} "qm status ${VM_ID}" | grep -i 'status:' | awk '{print $2}')" == "running" ]; do
        sleep $INTERVAL
      done
      echo -e "\033[1;32m[INFO]\033[0m The VM $VM_ID has been successfully shut down after forcing shutdown."
      break
    fi
  done
fi


echo -e "\n\033[1;36m[INFO]\033[0m Checking if VM $VM_ID already exists on node $DEST_NODE_IP...\n"
if ssh ${DEST_NODE_USER}@${DEST_NODE_IP} "test -f /etc/pve/qemu-server/${VM_ID}.conf"; then
  EXISTING_DISKS=$(ssh ${DEST_NODE_USER}@${DEST_NODE_IP} "grep -E '^(scsi|ide|sata|virtio)' /etc/pve/qemu-server/${VM_ID}.conf | grep -v 'none' | grep -v 'cdrom' | grep -v 'scsihw' | cut -d ',' -f1 | cut -d '=' -f2")
  IFS=$'\n'
  for DISK in $EXISTING_DISKS; do
    DISK_NAME=$(echo $DISK | grep -o '^[^:]*')
    DISK_PATH=$(echo $DISK | sed 's/^[^:]*: //')

    # Delete the disk only if it's still configured
    if ssh ${DEST_NODE_USER}@${DEST_NODE_IP} "grep -q ${DISK_NAME} /etc/pve/qemu-server/${VM_ID}.conf"; then
      ssh ${DEST_NODE_USER}@${DEST_NODE_IP} "qm set ${VM_ID} -delete ${DISK_NAME} && pvesm free ${DISK_PATH}"
      echo -e "\033[1;32m[INFO]\033[0m Disk ${DISK_NAME} successfully deleted."
    else
      echo -e "\033[1;33m[WARNING]\033[0m Disk ${DISK_NAME} not found in the current configuration, skipping deletion."
    fi
  done
fi

echo -e "\n\033[1;36m[INFO]\033[0m Copying configuration file and VM disks $VM_ID...\n"
ssh ${SOURCE_NODE_USER}@${SOURCE_NODE_IP} "scp /etc/pve/qemu-server/${VM_ID}.conf ${DEST_NODE_USER}@${DEST_NODE_IP}:/etc/pve/qemu-server/"

DISKS=$(ssh ${SOURCE_NODE_USER}@${SOURCE_NODE_IP} "grep -E '^(scsi|ide|sata|virtio)' /etc/pve/qemu-server/${VM_ID}.conf | grep -v 'none' | grep -v 'cdrom' | grep -v 'scsihw' | cut -d ',' -f1 | cut -d '=' -f2 | sed 's/^[^:]*: *//'")
TOTAL_DISKS=$(echo "$DISKS" | wc -l)
CURRENT_DISK=0

for DISK in $DISKS; do
  CURRENT_DISK=$((CURRENT_DISK + 1))
  echo -e "\033[1;33m[INFO]\033[0m Copying disk $CURRENT_DISK of $TOTAL_DISKS: $DISK..."
  ssh ${SOURCE_NODE_USER}@${SOURCE_NODE_IP} "pvesm export ${DISK} raw+size -" | ssh -o ServerAliveInterval=60 -o ServerAliveCountMax=120 ${DEST_NODE_USER}@${DEST_NODE_IP} "pvesm import ${DISK} raw+size -"
  echo -e "\033[1;32m[INFO]\033[0m Disk $CURRENT_DISK of $TOTAL_DISKS successfully copied.\n"
done

if [ "$SNAPSHOT" = true ]; then
  echo -e "\n\033[1;36m[INFO]\033[0m Removing references to snapshots in the configuration file...\n"
  ssh ${DEST_NODE_USER}@${DEST_NODE_IP} "sed -i '/^\[migracion_snapshot\]/,/^$/d' /etc/pve/qemu-server/${VM_ID}.conf"
fi

echo -e "\n\n\033[1;32m===== VM migration process $VM_ID completed successfully. =====\033[0m\n\n"
