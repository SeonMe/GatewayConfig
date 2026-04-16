!#/bin/bash


## nchnroutes
git clone https://github.com/dndx/nchnroutes.git
sed -i 's/default="wg0"/default="enp1s0"/g' /nchnroutes/produce.py
sed -i 's/IPv4Network('172.16.0.0/12')/IPv4Network('172.24.0.0/13')/g' /nchnroutes/produce.py

curl -o ipv4-address-space.csv https://www.iana.org/assignments/ipv4-address-space/ipv4-address-space.csv
curl -o delegated-apnic-latest https://ftp.apnic.net/stats/apnic/delegated-apnic-latest
curl -o china_ip_list.txt https://raw.githubusercontent.com/17mon/china_ip_list/master/china_ip_list.txt
python3 produce.py
mv routes4.conf /etc/bird/routes4.conf
mv routes6.conf /etc/bird/routes6.conf
birdc configure