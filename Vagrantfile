# -*- mode: ruby -*-
# vi: set ft=ruby :

provision_script = <<eos
apt-key adv --keyserver hkp://keyserver.ubuntu.com:80 --recv 7F0CEB10
echo 'deb http://downloads-distro.mongodb.org/repo/ubuntu-upstart dist 10gen' \
  | tee /etc/apt/sources.list.d/mongodb.list
apt-get update
apt-get install -y mongodb-org
service mongod stop || true

cat << EOF > /etc/mongod.conf
# mongod.conf
dbpath=/var/lib/mongodb
logpath=/var/log/mongodb/mongod.log
logappend=true
bind_ip = 0.0.0.0
replSet=rs0
oplogSize=1024
EOF

service mongod start
eos

nodes = 4
ips = (1...nodes).inject(['192.168.55.100']) { |l| l << l.last.succ }

Vagrant.configure(2) do |config|
  config.vm.box = 'bento/ubuntu-14.04'

  config.vm.provider "virtualbox" do |vb|
    # Customize the amount of memory on the VM:
    vb.memory = "1024"
  end

  1.upto(nodes) do |node|
    config.vm.define "mongo#{node}" do |mongo|
      mongo.vm.network :private_network, ip: ips[node - 1]
      # mongo.vm.provision "shell", inline: provision_script
    end
  end

  config.vm.provision 'shell', inline: provision_script
end
