#!/bin/bash
# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.

set -o errexit
set -o nounset
set -o errtrace

trap 'write_log "Install failed with exit code $?"' ERR

readonly log_file="/data/cromwellazure/install.log"
touch $log_file
exec 1>>$log_file
exec 2>&1

function write_log() {
    # Prepend the parameter value with the current datetime, if passed
    echo ${1+$(date --iso-8601=seconds) $1}
}

function wait_for_apt_locks() {
    i=0

    while fuser /var/lib/dpkg/lock /var/lib/dpkg/lock-frontend /var/lib/apt/lists/lock /var/cache/apt/archives/lock >/dev/null 2>&1; do
        if [ $i -gt 20 ]; then
            write_log 'Timed out while waiting for release of apt locks'
            exit 1
        else
            write_log 'Waiting for release of apt locks'
            sleep 30
        fi

        let i=i+1
    done
}

# Takes a two parameters, a value to look for in $1 and an array to check in $2
# Loop over the array, ignoring quotes for the array value and compare to the supplied value.
# Ignores quotes so "/mnt" will still match /mnt.
# If the value is found, break and return 0(True), else return 1(False) at the end.
function containsElement () { for e in "${@:2}"; do [[ "${e//\"/}" = "$1" ]] && return 0; done; return 1; }


# Function that takes a multiline string of the format key="value1 value2 value3" on each line, key value, and new list value.
# Append the new value to the end of the list for specified key, if it does not already exist.
# Parameter $1 Key value
# Parameter $2 New list value
# Parameter $3 File string
# Returns: Original string, with new value added to the appropriate key list if not already present.
function appendKeyValueList()
{
    # Read through each line of the file, splitting the line on the '=' character into name and value variables.
    IFS="="
    while read -r name value
    do
       # Check if the key matches.
       if [[ "$name" == "$1" ]]; then
          # Parse the value list, into an array.
          # The string values at the start and end of list will get " characters attached.
          # Doing "value:1:-1" ignores the first and last characters to strip the quotes.
          IFS=' '; arrIN=(${value:1:-1}); IFS="=";

          # Check if the array already contains out new value, if not, add it to the list inside the quotes.
          if ! containsElement "$2" ${arrIN[@]}; then
             echo "$name=\"${value:1:-1} $2\""
          # If the array contains our new value, print the original line.
          else
             echo "$name=$value"
          fi
       # Line doesn't contain the key we are looking for so reprint the original line.
       else
          echo "$name=$value"
       fi
    # Directs the string in variable $3 into our loop.
    done < <(printf '%s\n' "$3")
    IFS=" "
}

write_log "Verifying that no other package updates are in progress"
wait_for_apt_locks

write_log "Install starting"

write_log "Installing docker and docker-compose"
sudo apt update
sudo apt install -y apt-transport-https ca-certificates curl software-properties-common
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo apt-key add -
sudo add-apt-repository -y "deb [arch=amd64] https://download.docker.com/linux/ubuntu bionic stable"
sudo apt update
sudo apt-cache policy docker-ce
sudo apt install -y docker-ce
sudo curl -L "https://github.com/docker/compose/releases/download/1.26.0/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
sudo chmod +x /usr/local/bin/docker-compose
sudo docker-compose --version

write_log "Installing blobfuse"
ubuntuVersion=$(lsb_release -ar 2>/dev/null | grep -i release | cut -s -f2)
sudo wget https://packages.microsoft.com/config/ubuntu/$ubuntuVersion/packages-microsoft-prod.deb
sudo dpkg -i packages-microsoft-prod.deb
sudo apt update
sudo apt install -y --allow-downgrades blobfuse=1.4.3 fuse

write_log "Installing az cli"
curl -sL https://aka.ms/InstallAzureCLIDeb | sudo bash

write_log "Applying security patches"
sudo unattended-upgrades -v

if [ -d "/mysql" ]; then
    write_log "Previous /mysql exists, moving it to /data/mysql"
    cd /data/cromwellazure
    sudo docker-compose stop &>/dev/null
    sudo mv /mysql /data
fi

sudo mkdir -p /data/mysql

if [ -d "/cromwellazure" ] && [ ! -L "/cromwellazure" ]; then
    write_log "Previous /cromwellazure exists, using it to create /data/cromwellazure/env-01-account-names.txt and env-04-settings.txt"
    egrep -o 'DefaultStorageAccountName.*|CosmosDbAccountName.*|BatchAccountName.*|ApplicationInsightsAccountName.*' /cromwellazure/docker-compose.yml | sort -u > /data/cromwellazure/env-01-account-names.txt
    egrep -o 'DisableBatchScheduling.*|AzureOfferDurableId.*' /cromwellazure/docker-compose.yml | sort -u > /data/cromwellazure/env-04-settings.txt
    echo "UsePreemptibleVmsOnly=false" >> /data/cromwellazure/env-04-settings.txt
    grep -q 'DisableBatchScheduling' /data/cromwellazure/env-04-settings.txt || echo "DisableBatchScheduling=false" >> /data/cromwellazure/env-04-settings.txt
    write_log "Moving previous /cromwellazure to /cromwellazure-backup"
    sudo mv /cromwellazure /cromwellazure-backup
fi

if [ ! -L "/cromwellazure" ]; then
    write_log "Creating symlink /cromwellazure -> /data/cromwellazure"
    sudo ln -s /data/cromwellazure /cromwellazure
fi

# Prevent blobfuse mounts from being indexed by mlocation https://github.com/Azure/azure-storage-fuse/wiki/Blobfuse-Troubleshoot-FAQ#common-problems-after-a-successful-mount
# Load config variable with the contents of /etc/updatedb.conf
# Add each new value to the appropriate section of the file.
config=$(cat /etc/updatedb.conf)
config=$(appendKeyValueList "PRUNEPATHS" "/mnt" "$config")
config=$(appendKeyValueList "PRUNEFS" "blobfuse" "$config")
config=$(appendKeyValueList "PRUNEFS" "blobfuse2" "$config")
config=$(appendKeyValueList "PRUNEFS" "fuse" "$config")
printf '%s\n' "$config" > /etc/updatedb.conf

write_log "Disabling the Docker service, because the cromwellazure service is responsible for starting Docker"
sudo systemctl disable docker

write_log "Enabling cromwellazure service"
sudo systemctl enable cromwellazure.service

write_log "Install complete"
