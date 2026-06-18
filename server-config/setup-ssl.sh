#!/bin/bash

# SSL Setup Script for GraniVPN
# Domains: admin.granilink.com, app.granilink.com, api.granilink.com

set -e

echo "🔒 Setting up SSL certificates for GraniVPN domains..."

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Function to print colored output
print_status() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Check if running as root
if [[ $EUID -ne 0 ]]; then
   print_error "This script must be run as root"
   exit 1
fi

# Update system
print_status "Updating system packages..."
apt update && apt upgrade -y

# Install required packages
print_status "Installing required packages..."
apt install -y certbot python3-certbot-nginx nginx

# Create SSL directory
mkdir -p /etc/letsencrypt

# Domains to configure
DOMAINS=("admin.granilink.com" "app.granilink.com" "api.granilink.com")
EMAIL="rail.tamaew@gmail.com"

# Temporary Nginx config for SSL verification
print_status "Creating temporary Nginx configuration..."
cat > /etc/nginx/sites-available/granivpn-temp << 'EOF'
server {
    listen 80;
    server_name admin.granilink.com app.granilink.com api.granilink.com;
    
    location /.well-known/acme-challenge/ {
        root /var/www/html;
    }
    
    location / {
        return 301 https://$server_name$request_uri;
    }
}
EOF

# Enable temporary site
ln -sf /etc/nginx/sites-available/granivpn-temp /etc/nginx/sites-enabled/
rm -f /etc/nginx/sites-enabled/default

# Test Nginx configuration
print_status "Testing Nginx configuration..."
nginx -t

# Start Nginx
print_status "Starting Nginx..."
systemctl start nginx
systemctl enable nginx

# Get SSL certificates
print_status "Obtaining SSL certificates..."

for domain in "${DOMAINS[@]}"; do
    print_status "Getting certificate for $domain..."
    
    # Stop Nginx temporarily for certbot
    systemctl stop nginx
    
    # Get certificate
    certbot certonly --standalone \
        --email $EMAIL \
        --agree-tos \
        --no-eff-email \
        --domains $domain \
        --non-interactive
    
    # Start Nginx
    systemctl start nginx
    
    print_status "Certificate obtained for $domain"
done

# Copy production Nginx configuration
print_status "Installing production Nginx configuration..."
cp /root/server-config/nginx/production.conf /etc/nginx/sites-available/granivpn-production
ln -sf /etc/nginx/sites-available/granivpn-production /etc/nginx/sites-enabled/
rm -f /etc/nginx/sites-enabled/granivpn-temp

# Test Nginx configuration
print_status "Testing production Nginx configuration..."
nginx -t

# Reload Nginx
print_status "Reloading Nginx..."
systemctl reload nginx

# Setup automatic renewal
print_status "Setting up automatic SSL renewal..."
(crontab -l 2>/dev/null; echo "0 12 * * * /usr/bin/certbot renew --quiet") | crontab -

# Create renewal script
cat > /usr/local/bin/renew-ssl.sh << 'EOF'
#!/bin/bash
certbot renew --quiet
systemctl reload nginx
EOF

chmod +x /usr/local/bin/renew-ssl.sh

# Test SSL certificates
print_status "Testing SSL certificates..."
for domain in "${DOMAINS[@]}"; do
    echo "Testing $domain..."
    curl -I https://$domain > /dev/null 2>&1 && print_status "$domain SSL is working" || print_error "$domain SSL failed"
done

print_status "SSL setup completed successfully!"
print_status "Domains configured:"
for domain in "${DOMAINS[@]}"; do
    echo "  - https://$domain"
done

print_warning "Remember to configure DNS records pointing to this server IP: 94.131.107.227"
print_status "SSL certificates will auto-renew every 60 days"







