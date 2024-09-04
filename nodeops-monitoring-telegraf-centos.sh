#!/bin/bash
# Check if the script is running as root
if [ "$EUID" -ne 0 ]; then
    echo "This script must be run as root."
    exit 1
fi

echo "_____Updating packeges_____"

yum update

yum install unzip -y

curl -LO https://github.com/grafana/loki/releases/latest/download/promtail-linux-amd64.zip

unzip promtail-linux-amd64.zip

chmod a+x promtail-linux-amd64
mv promtail-linux-amd64 /usr/bin/promtail

mkdir /etc/promtail

curl -L https://raw.githubusercontent.com/grafana/loki/master/docs/clients/aws/ec2/promtail-ec2.yaml -o /etc/promtail/promtail.yaml


echo "promtail installation completed."

# Copy promtail service configuration
echo "Copying promtail service configuration..."
 tee /etc/systemd/system/promtail.service << EOF
[Unit]
Description=Promtail service
After=network.target

[Service]
Type=simple
User=root
ExecStart=/usr/bin/promtail -config.file /etc/promtail/config.yml
TimeoutSec=60
Restart=on-failure
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF

# Restart promtail service
echo "Restarting promtail service..."
 systemctl daemon-reload
 systemctl restart promtail

echo "Done!"


# Get public IP address
# public_ip=$(curl ifconfig.me)
read -p "Please enter the Public IPV4 address of the server: " public_ip

# Confirm the provided log path
echo "You entered: $public_ip"
read -p "Is this correct? (y/n) " confirm
if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
    echo "Public IPV4 address confirmed: $public_ip"
else
    echo "Public IPV4 address not confirmed. Please try again."
    exit 1
fi

# Get hostname
hostname=$(hostname)


CPU_MAX=$(lscpu | grep '^CPU(s):' | awk '{print $2}')

MEM_MAX=$(grep MemTotal /proc/meminfo | awk '{sub(/^[ \t]+/, "", $2); sub(/ kB$/, "", $2); print $2 * 1024}')

DISK_SIZE=$(df -B1 / | awk 'NR==2 {print $2}')

uuid=$(uuidgen)
uuid_2=$(uuidgen)
title="Logs-$hostname-$public_ip"
job="$hostname-$public_ip"
folder_uuid=$(uuidgen)
folder_name="$hostname-$public_ip-Dashboard"
metric_name="Metric-$hostname-$public_ip"
export folder_name="$hostname-$public_ip-Dashboard"
echo "Job name is, $job"

echo "Title name is $title"

# Ask the user for the log file path
read -p "Please enter the log file path: " log_path

# Confirm the provided log path
echo "You entered: $log_path"
read -p "Is this correct? (y/n) " confirm
if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
    echo "Log file path confirmed: $log_path"
else
    echo "Log file path not confirmed. Please try again."
    exit 1
fi

cat << EOF > /etc/promtail/config.yml
server:
  http_listen_port: 9080
  grpc_listen_port: 0

positions:
  filename: /tmp/positions.yaml

clients:
  - url: https://loki.services.supra.com/loki/api/v1/push

scrape_configs:
  - job_name: smr
    static_configs:
      - targets:
        - localhost
        labels:
          job: $job
          __path__: "$log_path"
EOF

service promtail restart

systemctl enable promtail.service


### Checking for the old dashboard and remove it if exist####

echo "Deleting the Folder if exists"

curl -X POST -H "Authorization: Bearer AIzaSyD5ZGqOBqV1VbydmcoqXGskmNR9gHWbqkc" \
     -H "Content-Type: application/json" \
     -d "{
            \"folder_name\": \"$folder_name\"
         }" \
     https://secure-api.services.supra.com/monitoring-supra-delete-folder


# creating dashboard

echo "Creating new folder"

echo "Folder Name: $folder_name"
echo "Folder UUDI: $folder_uuid"

curl -X POST -H "Authorization: Bearer AIzaSyD5ZGqOBqV1VbydmcoqXGskmNR9gHWbqkc" \
     -H "Content-Type: application/json" \
     -d "{
            \"folder_name\": \"$folder_name\",
            \"folder_uuid\": \"$folder_uuid\"
         }" \
     https://secure-api.services.supra.com/monitoring-supra-create-folder


echo "Created new folder"


echo "Updating Dashboard!"

# file_content=$(<dashboard.json)
file_content=$(curl -sL "https://gist.github.com/Supra-RaghulRajeshR/33d027b21be6f190c0c66e34fee3a9a1/raw/ccd84b760a6319209934e87aaebe5bcf5664f47a/node-logs.json")


updated_content=$(echo "$file_content" | sed "s/\"title\": \"\$title\"/\"title\": \"$title\"/g; s/\"uid\": \"\$uuid\"/\"uid\": \"$uuid\"/g; s/job=\$job_name/job=\`$job\`/g; s/{{ folder_uuid }}/$folder_uuid/g")


# Write the updated content back to the file
echo "$updated_content" > new-dashboard.json

echo "Dashboard Updated!"

echo "Creating Dashboard FOR LOKI IN GRAFANA"


curl -X POST -H "Authorization: Bearer AIzaSyD5ZGqOBqV1VbydmcoqXGskmNR9gHWbqkc" \
     -H "Content-Type: application/json" \
     -d "{\"data\": $updated_content}" \
     https://secure-api.services.supra.com/monitoring-supra-create-dashboard


echo "Dashboard creation request sent!"


rm -rf new-dashboard.json 


sleep 2

echo "installing telegraf agent"

cat <<EOF | sudo tee /etc/yum.repos.d/influxdb.repo
[influxdb]
name = InfluxData Repository - Stable
baseurl = https://repos.influxdata.com/stable/\$basearch/main
enabled = 1
gpgcheck = 1
gpgkey = https://repos.influxdata.com/influxdata-archive_compat.key
EOF

yum update && yum install telegraf sysstat -y

rm /etc/telegraf/telegraf.conf*

curl -L  https://gist.githubusercontent.com/Supra-RaghulRajeshR/33d027b21be6f190c0c66e34fee3a9a1/raw/83dd5336c537ae7e6fcfda6ba5aaacc1c575bbdb/telegraf-centos.conf  -o  /etc/telegraf/telegraf.conf

curl -L https://gist.githubusercontent.com/Supra-RaghulRajeshR/33d027b21be6f190c0c66e34fee3a9a1/raw/58766426b95347313d30232b1720234089178303/telegraf.service -o /usr/lib/systemd/system/telegraf.service
systemctl daemon-reload
systemctl restart telegraf.service
systemctl enable telegraf.service

echo "updating dashboard"

sleep 2


file_content=$(curl -sL "https://gist.githubusercontent.com/Supra-RaghulRajeshR/33d027b21be6f190c0c66e34fee3a9a1/raw/985fa5d9478441f8b62d68891fef695305f4f0c6/telegraf-metrics.json")


updated_content=$(echo "$file_content" | sed "s/{{ uuid_2 }}/$uuid_2/g; s/{{ job_name }}/$hostname/g; s/{{ folder_uuid }}/$folder_uuid/g; s/{{ metric_name }}/$metric_name/g; s/{{ metric_name }}/$metric_name/g; s/{{ CPU_MAX }}/$CPU_MAX/g; s/{{ MEM_MAX }}/$MEM_MAX/g; s/{{ DISK_SIZE }}/$DISK_SIZE/g")
# Write the updated content back to the file
echo "$updated_content" > new-telegraf-metrics.json

# sed "s/{{ job_name }}/$job/g"  



echo "Dashboard Updated!"

echo "Creating Dashboard"

curl -X POST -H "Authorization: Bearer AIzaSyD5ZGqOBqV1VbydmcoqXGskmNR9gHWbqkc" \
     -H "Content-Type: application/json" \
     -d "{\"data\": $updated_content}" \
     https://secure-api.services.supra.com/monitoring-supra-create-dashboard


rm new-telegraf-metrics.json

read -p "Please specify e-mail for dashboard access: " email

share_result=$(echo {email: $email, dashboard: $folder_name})

echo  "Share the following information with Supra Team to get access to the dashboard:\n$share_result"

echo "Grafana dashboard url:  https://monitoring.services.supra.com/dashboards/f/$folder_uuid"
