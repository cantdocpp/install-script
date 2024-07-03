#!/bin/bash

DOCKER_VERSION="26.0"
PG_VERSION="16"

OS_TYPE=$(grep -w "ID" /etc/os-release | cut -d "=" -f 2 | tr -d '"')
OS_VERSION=$(grep -w "VERSION_ID" /etc/os-release | cut -d "=" -f 2 | tr -d '"')

if [ $EUID != 0 ]; then
    echo "Please run as root"
    exit
fi

if [ "$OS_TYPE" != 'ubuntu' ]; then
    echo "Script can only be run at ubuntu machine"
    exit
fi

echo -e "-------------"
echo -e "Running installation scripts..."
echo -e "(Source code: https://github.com/gboengineering/gbo-scripts)\n"
echo -e "-------------"

echo "OS: $OS_TYPE $OS_VERSION"

if ! [ -x "$(command -v docker)" ]; then
    echo -e "Installing docker"
    curl https://releases.rancher.com/install-docker/${DOCKER_VERSION}.sh | sh
fi

if ! [ -x "$(command -v psql)" ]; then
    echo -e "Installing postgresql"
    sudo apt install curl ca-certificates
    sudo install -d /usr/share/postgresql-common/pgdg
    sudo curl -o /usr/share/postgresql-common/pgdg/apt.postgresql.org.asc --fail https://www.postgresql.org/media/keys/ACCC4CF8.asc
    sudo sh -c 'echo "deb [signed-by=/usr/share/postgresql-common/pgdg/apt.postgresql.org.asc] https://apt.postgresql.org/pub/repos/apt $(lsb_release -cs)-pgdg main" > /etc/apt/sources.list.d/pgdg.list'
    sudo apt update
    sudo apt -y install postgresql-$PG_VERSION

    # Variables
    PG_USER="gbo"
    PG_PASSWORD="gbo123"
    PG_DATABASE="tipster"

    sudo -i -u postgres bash << EOF
# Create new PostgreSQL user
psql -c "CREATE USER $PG_USER WITH PASSWORD '$PG_PASSWORD';"

# Create new PostgreSQL database
psql -c "CREATE DATABASE $PG_DATABASE OWNER $PG_USER;"

# Grant all privileges on the new database to the new user
psql -c "GRANT ALL PRIVILEGES ON DATABASE $PG_DATABASE TO $PG_USER;"
EOF

    sudo sed -i "s/#listen_addresses = 'localhost'/listen_addresses = '*'/" /etc/postgresql/$PG_VERSION/main/postgresql.conf
    echo "host    all             all             0.0.0.0/0               md5" | sudo tee -a /etc/postgresql/$PG_VERSION/main/pg_hba.conf
    sudo sed -i "s/^timezone = .*/timezone = 'Asia/Jakarta'/" /etc/postgresql/$PG_VERSION/main/postgresql.conf

    sudo systemctl restart postgresql

    echo "PostgreSQL installation and configuration complete."
    echo "User: $PG_USER"
    echo "Database: $PG_DATABASE"
fi

if ! [ -x "$(command -v node)" ]; then
    export HOME=/home/ubuntu
    # installs nvm (Node Version Manager)
    su - ubuntu -c "curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.7/install.sh | bash"
    su - ubuntu -c "export NVM_DIR=\"$HOME/.nvm\""
    su - ubuntu -c "[ -s \"$NVM_DIR/nvm.sh\" ] && \. \"$NVM_DIR/nvm.sh\""
    su - ubuntu -c "[ -s \"$NVM_DIR/bash_completion\" ] && \. \"$NVM_DIR/bash_completion\""

    source ~/.bash_profile
    source ~/.bashrc
    source ~/.nvm/nvm.sh
    
    # download and install Node.js
    nvm install 20
    # verifies the right Node.js version is in the environment
    node -v # should print `v20.13.1`
    # verifies the right NPM version is in the environment
    npm -v # should print `10.5.2`
    nvm cache clear
fi

if ! [ -x "$(command -v pm2)" ]; then
    npm install pm2 -g
fi

# set timezone to jakarta
sudo timedatectl set-timezone Asia/Jakarta

# install nginx
# https://stackoverflow.com/questions/66076321/whats-the-purpose-of-ppaondrej-nginx
if ! [ -x "$(command -v nginx)" ]; then
    sudo apt update
    sudo apt install -y build-essential libpcre3 libpcre3-dev libssl-dev zlib1g-dev wget unzip

    # Download Nginx and RTMP module source
    wget http://nginx.org/download/nginx-1.21.4.tar.gz
    wget https://github.com/arut/nginx-rtmp-module/archive/master.zip
    tar -zxvf nginx-1.21.4.tar.gz
    unzip master.zip

    # Compile Nginx with RTMP module
    cd nginx-1.21.4
    ./configure --add-module=../nginx-rtmp-module-master --with-http_ssl_module
    make
    sudo make install

    # Create Nginx configuration
    sudo tee /usr/local/nginx/conf/nginx.conf > /dev/null <<EOL
worker_processes auto;

events {
    worker_connections 1024;
}

rtmp {
    server {
        listen 1935;
        chunk_size 4096;

        application live {
            live on;
            record off;
        }
    }
}

http {
    include       mime.types;
    default_type  application/octet-stream;

    sendfile        on;
    keepalive_timeout  65;

    include /usr/local/nginx/conf.d/*.conf;
    include /usr/local/nginx/sites-enabled/*;
}
EOL

    # Create directories for site configurations
    sudo mkdir -p /usr/local/nginx/sites-available
    sudo mkdir -p /usr/local/nginx/sites-enabled
    sudo mkdir -p /usr/local/nginx/conf.d

    # Create a sample site configuration
    sudo tee /usr/local/nginx/sites-available/livestream.gbotipster.net > /dev/null <<EOL
server {
    listen 80;
    server_name livestream.gbotipster.net;

    location / {
        proxy_pass http://localhost:8000;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }

    location /live {
        proxy_pass http://localhost:1935;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOL

    # Enable the site configuration
    sudo ln -s /usr/local/nginx/sites-available/livestream.gbotipster.net /usr/local/nginx/sites-enabled/
    sudo /usr/local/nginx/sbin/nginx
    sudo systemctl enable nginx
fi

source ~/.bashrc
