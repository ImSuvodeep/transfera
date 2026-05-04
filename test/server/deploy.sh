#!/bin/bash
# Transfera Deployment Script for Linux VPS
# This script sets up the Signaling Server and Coturn using Docker

echo "🚀 Starting Transfera Deployment..."

# 1. Update and install Docker if not present
if ! [ -x "$(command -v docker)" ]; then
  echo "Installing Docker..."
  curl -fsSL https://get.docker.com -o get-docker.sh
  sh get-docker.sh
fi

# 2. Setup Nginx for SSL (mandatory for WSS)
echo "Setting up Nginx & Certbot..."
# Assuming Ubuntu/Debian
# sudo apt-get update && sudo apt-get install -y nginx certbot python3-certbot-nginx

# 3. Create Nginx config (Template)
cat <<EOF > /etc/nginx/sites-available/transfera
server {
    server_name YOUR_DOMAIN.com;

    location / {
        proxy_pass http://localhost:3000;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
    }

    # For Deep Links (AASA file)
    location /.well-known/apple-app-site-association {
        default_type application/json;
    }

    location /.well-known/assetlinks.json {
        default_type application/json;
    }
}
EOF

# 4. Start Docker Stack
echo "Starting Docker Compose..."
docker-compose up -d --build

echo "✅ Deployment initiated. Next steps:"
echo "1. Run 'certbot --nginx' to enable SSL."
echo "2. Update your app code with 'wss://YOUR_DOMAIN.com'."
echo "3. Upload /.well-known/ files to the server root."
