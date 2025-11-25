#!/bin/sh

read -p "Enter newt setup command: " NEWT_SETUP </dev/tty

if [ ! $NEWT_SETUP newt* ]; then
  echo "Invalid command"
  return 1
fi

NEWT_SERVICE="/etc/init.d/newt"

echo "Installing newt component...."

which newt &>/dev/null || wget -qO- https://pangolin.net/get-newt.sh | sh

echo "Configuring newt..."
output=$(timeout 5 $NEWT_SETUP 2>&1)
echo "$output"

# Check for connection failure
if echo "$output" | grep -qi "failed to connect"; then
  echo "Error: Failed to connect detected. Aborting setup."
  exit 1
fi

echo "Creating newt service..."

rm -f "$NEWT_SERVICE"
cat <<EOF > "$NEWT_SERVICE"
#!/sbin/openrc-run

description="Pangolin Newt secure tunnel client"
command="/usr/local/bin/newt"
command_background="yes"
pidfile="/var/run/newt.pid"
output_log="/var/log/newt.log"
error_log="/var/log/newt.err"

depend() {
    need net
    after firewall
}
EOF

chmod +x "$NEWT_SERVICE"

echo "Starting newt service and setuping runlevel..."

service newt start
service newt status

rc-update add newt default

echo "Setting up dns resolution..."
apk add --no-cache dnsmasq
cat <<EOF > /etc/dnsmasq.d/new.conf
server=/iface.infra.unxwares.com/10.127.30.2
server=9.9.9.9
EOF

rc-update add dnsmasq default
service dnsmasq restart

rm -f /etc/resolv.conf
cat <<EOF > /etc/resolv.conf
nameserver 127.0.0.1
EOF

echo "Newt successfully installed 🤓 !"
