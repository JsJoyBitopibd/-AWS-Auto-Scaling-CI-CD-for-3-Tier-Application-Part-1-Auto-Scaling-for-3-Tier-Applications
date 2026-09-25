#!/bin/bash
# =====================================================================
#  Bitopi 3-Tier Assignment  -  DATABASE SERVER user-data
#  Runs automatically on first boot of the DB EC2 instance.
#  Installs MariaDB (MySQL-compatible), creates the app database,
#  an app user, and a seed table. No manual steps needed.
# =====================================================================
exec > >(tee /var/log/user-data.log) 2>&1
set -x

# 1) Install and start MariaDB (MySQL-compatible server)
dnf install -y mariadb105-server
systemctl enable --now mariadb

# 2) Make MySQL listen on all interfaces so the app servers can reach it
cat >/etc/my.cnf.d/99-app.cnf <<'EOF'
[mysqld]
bind-address=0.0.0.0
EOF
systemctl restart mariadb

# 3) Create the application database, a remote-capable user, and seed data
mysql <<'SQL'
CREATE DATABASE IF NOT EXISTS appdb;
CREATE USER IF NOT EXISTS 'appuser'@'%' IDENTIFIED BY 'Bitopi#Db2026';
GRANT ALL PRIVILEGES ON appdb.* TO 'appuser'@'%';
FLUSH PRIVILEGES;
USE appdb;
CREATE TABLE IF NOT EXISTS app_info (id INT PRIMARY KEY, info VARCHAR(255));
INSERT IGNORE INTO app_info (id, info)
  VALUES (1, 'Bitopi 3-Tier App - data served live from MySQL on EC2');
CREATE TABLE IF NOT EXISTS visits (
  id INT AUTO_INCREMENT PRIMARY KEY,
  hostname VARCHAR(255),
  visited_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);
SQL

echo "===== Bitopi DB setup complete ====="
