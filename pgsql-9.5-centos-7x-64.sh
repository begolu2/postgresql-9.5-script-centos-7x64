#!/bin/bash -e
#Version: 0.7.3
#MapFig, Inc

touch /root/auth.txt
UNPRIV_USER='pgadmin'
yum install -y redhat-lsb-core
CENTOS_VER=$(lsb_release -sr | cut -f1 -d.)
if [ $(uname -m) == 'x86_64' ]; then
  CENTOS_ARCH='x86_64'
else
  CENTOS_ARCH='i386'
fi

function install_postgresql(){
	#1. Install PostgreSQL repo
	if [ ! -f /etc/yum.repos.d/pgdg-95-centos.repo ]; then
		rpm -ivh http://yum.pgrpms.org/9.5/redhat/rhel-${CENTOS_VER}-${CENTOS_ARCH}/pgdg-centos95-9.5-2.noarch.rpm
	fi

	#2. Disable CentOS repo for PostgreSQL
	if [ $(grep -m 1 -c 'exclude=postgresql' /etc/yum.repos.d/CentOS-Base.repo) -eq 0 ]; then
		sed -i.save '/\[base\]/a\exclude=postgresql*' /etc/yum.repos.d/CentOS-Base.repo
		sed -i.save '/\[updates\]/a\exclude=postgresql*' /etc/yum.repos.d/CentOS-Base.repo
	fi

	#2. Install PostgreSQL
	yum install -y postgresql95 postgresql95-devel postgresql95-server postgresql95-libs postgresql95-contrib postgresql95-plperl postgresql95-plpython postgresql95-pltcl postgresql95-python postgresql95-odbc postgresql95-jdbc perl-DBD-Pg

	export PGDATA='/var/lib/pgsql/9.5/data'
	export PATH="${PATH}:/usr/pgsql-9.5/bin/"
	if [ $(grep -m 1 -c '/usr/pgsql-9.5/bin/' /etc/environment) -eq 0 ]; then
		echo "${PATH}" >> /etc/environment
	fi

	if [ $(grep -m 1 -c 'PGDATA' /etc/environment) -eq 0 ]; then
		echo "${PGDATA}" >> /etc/environment
	fi

	if [ ! -f /var/lib/pgsql/9.5/data/pg_hba.conf ]; then
		sudo -u postgres /usr/pgsql-9.5/bin/initdb -D /var/lib/pgsql/9.5/data
	fi

	systemctl start postgresql-9.5

	#3. Set postgres Password
	if [ $(grep -m 1 -c 'pg pass' /root/auth.txt) -eq 0 ]; then
		PG_PASS=$(< /dev/urandom tr -dc _A-Z-a-z-0-9 | head -c32);
		sudo -u postgres psql 2>/dev/null -c "alter user postgres with password '${PG_PASS}'"
		echo "pg pass: ${PG_PASS}" > /root/auth.txt
	fi

	#4. Configure ph_hba.conf and postgresql.conf for md5 and ssl
	cat >/var/lib/pgsql/9.5/data/pg_hba.conf <<CMD_EOF
local	all all 							md5
host	all all 127.0.0.1	255.255.255.255	md5
host	all all 0.0.0.0/0					md5
host	all all ::1/128						md5
hostssl all all 127.0.0.1	255.255.255.255	md5
hostssl all all 0.0.0.0/0					md5
hostssl all all ::1/128						md5
CMD_EOF
	sed -i.save "s/.*listen_addresses.*/listen_addresses = '*'/" /var/lib/pgsql/9.5/data/postgresql.conf
	sed -i.save "s/.*ssl =.*/ssl = on/" /var/lib/pgsql/9.5/data/postgresql.conf

	#5. Create Symlinks for Backward Compatibility from PostgreSQL 9 to PostgreSQL 8
	ln -sf /usr/pgsql-9.5/bin/pg_config /usr/bin
	ln -sf /var/lib/pgsql/9.5/data /var/lib/pgsql
	ln -sf /var/lib/pgsql/9.5/backups /var/lib/pgsql

	#6. create self-signed SSL certificates
	if [ ! -f /var/lib/pgsql/9.5/data/server.key -o ! -f /var/lib/pgsql/9.5/data/server.crt ]; then
		SSL_PASS=$(< /dev/urandom tr -dc _A-Z-a-z-0-9 | head -c32);
		if [ $(grep -m 1 -c 'ssl pass' /root/auth.txt) -eq 0 ]; then
			echo "ssl pass: ${SSL_PASS}" >> /root/auth.txt
		else
			sed -i.save "s/ssl pass:.*/ssl pass: ${SSL_PASS}/" /root/auth.txt
		fi
		openssl genrsa -des3 -passout pass:${SSL_PASS} -out server.key 1024
		openssl rsa -in server.key -passin pass:${SSL_PASS} -out server.key

		chmod 400 server.key

		openssl req -new -key server.key -days 3650 -out server.crt -passin pass:${SSL_PASS} -x509 -subj '/C=CA/ST=Frankfurt/L=Frankfurt/O=brainfurnace.com/CN=brainfurnace.com/emailAddress=info@brainfurnace.com'
		chown postgres.postgres server.key server.crt
		mv server.key server.crt /var/lib/pgsql/9.5/data
	fi

	systemctl restart postgresql-9.5
}

function install_webmin(){
	yum -y install perl-Net-SSLeay
	if [ ! -d /usr/libexec/webmin/ ]; then
		rpm -ivh http://www.webmin.com/download/rpm/webmin-current.rpm
	fi
	#7. Set webmin config
	cat >/etc/webmin/postgresql/config <<EOF
simple_sched=0
sameunix=1
date_subs=0
max_text=1000
perpage=25
stop_cmd=systemctl stop postgresql-9.5
psql=/usr/bin/psql
pid_file=/var/run/postmaster-9.5.pid
hba_conf=/var/lib/pgsql/9.5/data/pg_hba.conf
setup_cmd=systemctl initdb postgresql-9.5; systemctl start postgresql-9.5
user=postgres
nodbi=0
max_dbs=50
start_cmd=systemctl start postgresql-9.5
repository=/var/lib/pgsql/9.5/backups
dump_cmd=/usr/bin/pg_dump
access=*: *
webmin_subs=0
style=0
rstr_cmd=/usr/bin/pg_restore
access_own=0
login=postgres
basedb=template1
add_mode=1
blob_mode=0
pass=${PG_PASS}
plib=
encoding=
port=
host=
EOF
}

function secure_ssh(){
	if [ $(grep -m 1 -c ${UNPRIV_USER} /etc/passwd) -eq 0 ]; then
		useradd -m ${UNPRIV_USER}
	fi

	if [ $(grep -m 1 -c "${UNPRIV_USER} pass" /root/auth.txt) -eq 0 ]; then
		USER_PASS=$(< /dev/urandom tr -dc _A-Z-a-z-0-9 | head -c32);
		echo "${UNPRIV_USER}:${USER_PASS}" | chpasswd
		echo "${UNPRIV_USER} pass: ${USER_PASS}" >> /root/auth.txt
	fi

	sed -i.save 's/#\?Port [0-9]\+/Port 3838/' /etc/ssh/sshd_config
	sed -i.save 's/#\?PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config
	systemctl restart sshd
}

install_postgresql;
install_webmin;
secure_ssh;

yum -y install pgbouncer

#change root password
if [ $(grep -m 1 -c 'root pass' /root/auth.txt) -eq 0 ]; then
	ROOT_PASS=$(< /dev/urandom tr -dc _A-Z-a-z-0-9 | head -c32);
	echo "root:${ROOT_PASS}" | chpasswd
	echo "root pass: ${ROOT_PASS}" >> /root/auth.txt
fi

echo "Passwords saved in /root/auth.txt"
cat /root/auth.txt
