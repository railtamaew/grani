#!/bin/sh
set -eu

CONF=/opt/grani/server-config/nginx/nginx.conf
WEBROOT=/opt/grani/server-config/static-pages
CERTBOT_IMAGE=certbot/certbot
ORIGIN_IP=159.223.199.122

mkdir -p "$WEBROOT/.well-known/acme-challenge"
printf 'ok-granilink-cutover\n' > "$WEBROOT/.well-known/acme-challenge/grani-cutover-test"

for domain in granilink.com www.granilink.com admin.granilink.com app.granilink.com; do
  body="$(curl -fsSL --max-time 20 "http://$domain/.well-known/acme-challenge/grani-cutover-test" || true)"
  if [ "$body" != "ok-granilink-cutover" ]; then
    echo "ACME HTTP check failed for $domain. Check Cloudflare DNS points to $ORIGIN_IP and disable forced HTTPS until certs are issued." >&2
    exit 1
  fi
done

docker run --rm \
  -v /etc/letsencrypt:/etc/letsencrypt \
  -v /var/lib/letsencrypt:/var/lib/letsencrypt \
  -v "$WEBROOT:/var/www/granivpn/static-pages" \
  "$CERTBOT_IMAGE" certonly --webroot \
    -w /var/www/granivpn/static-pages \
    --cert-name granilink.com \
    -d granilink.com -d www.granilink.com \
    --agree-tos --email support@granilink.com --non-interactive --keep-until-expiring --no-eff-email

for domain in admin.granilink.com app.granilink.com; do
  docker run --rm \
    -v /etc/letsencrypt:/etc/letsencrypt \
    -v /var/lib/letsencrypt:/var/lib/letsencrypt \
    -v "$WEBROOT:/var/www/granivpn/static-pages" \
    "$CERTBOT_IMAGE" certonly --webroot \
      -w /var/www/granivpn/static-pages \
      --cert-name "$domain" \
      -d "$domain" \
      --agree-tos --email support@granilink.com --non-interactive --keep-until-expiring --no-eff-email
done

cp "$CONF" "$CONF.bak-granilink-$(date +%Y%m%d%H%M%S)"
sed -i '/# BEGIN GRANILINK CUTOVER/,/# END GRANILINK CUTOVER/d' "$CONF"

tmp="$(mktemp)"
head -n -1 "$CONF" > "$tmp"
cat >> "$tmp" <<'NGINX'

    # BEGIN GRANILINK CUTOVER
    # --- granilink.com ---
    server {
        listen 443 ssl http2;
        server_name granilink.com www.granilink.com;

        ssl_certificate     /etc/letsencrypt/live/granilink.com/fullchain.pem;
        ssl_certificate_key /etc/letsencrypt/live/granilink.com/privkey.pem;
        ssl_protocols TLSv1.2 TLSv1.3;
        ssl_ciphers ECDHE-RSA-AES256-GCM-SHA512:DHE-RSA-AES256-GCM-SHA512:ECDHE-RSA-AES256-GCM-SHA384:DHE-RSA-AES256-GCM-SHA384;
        ssl_prefer_server_ciphers off;
        ssl_session_cache shared:SSL:10m;
        ssl_session_timeout 10m;

        add_header X-Frame-Options SAMEORIGIN;
        add_header X-Content-Type-Options nosniff;
        add_header X-XSS-Protection "1; mode=block";
        add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;

        set $grani_api_host api;

        location /.well-known/acme-challenge/ {
            root /var/www/granivpn/static-pages;
            try_files $uri =404;
        }

        location /api/ {
            proxy_pass http://$grani_api_host:8000;
            proxy_http_version 1.1;
            proxy_set_header Connection "";
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto $scheme;
            proxy_set_header X-Request-ID $log_request_id;
            proxy_connect_timeout 60s;
            proxy_send_timeout 130s;
            proxy_read_timeout 130s;
        }

        location /health {
            proxy_pass http://$grani_api_host:8000;
            proxy_http_version 1.1;
            proxy_set_header Connection "";
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto $scheme;
            proxy_set_header X-Request-ID $log_request_id;
        }

        location = /privacy {
            alias /var/www/granivpn/static-pages/privacy.html;
            add_header Content-Type "text/html; charset=utf-8";
        }

        location / {
            return 200 "GRANI";
            add_header Content-Type text/plain;
        }
    }

    # --- admin.granilink.com ---
    server {
        listen 443 ssl http2;
        server_name admin.granilink.com;

        ssl_certificate     /etc/letsencrypt/live/admin.granilink.com/fullchain.pem;
        ssl_certificate_key /etc/letsencrypt/live/admin.granilink.com/privkey.pem;
        ssl_protocols TLSv1.2 TLSv1.3;
        ssl_ciphers ECDHE-RSA-AES256-GCM-SHA512:DHE-RSA-AES256-GCM-SHA512:ECDHE-RSA-AES256-GCM-SHA384:DHE-RSA-AES256-GCM-SHA384;
        ssl_prefer_server_ciphers off;
        ssl_session_cache shared:SSL:10m;
        ssl_session_timeout 10m;

        add_header X-Frame-Options SAMEORIGIN;
        add_header X-Content-Type-Options nosniff;
        add_header X-XSS-Protection "1; mode=block";
        add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;

        limit_req zone=admin burst=10 nodelay;

        set $grani_api_host api;

        root /var/www/granivpn/admin-build;
        index index.html;

        location /.well-known/acme-challenge/ {
            root /var/www/granivpn/static-pages;
            try_files $uri =404;
        }

        location /api/ {
            proxy_pass http://$grani_api_host:8000;
            proxy_http_version 1.1;
            proxy_set_header Connection "";
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto $scheme;
            proxy_set_header X-Request-ID $log_request_id;
            proxy_connect_timeout 60s;
            proxy_send_timeout 130s;
            proxy_read_timeout 130s;
        }

        location /static/ {
            expires 1y;
            add_header Cache-Control "public, immutable";
        }

        location / {
            try_files $uri $uri/ /index.html;
            add_header Cache-Control "no-cache, no-store, must-revalidate";
            add_header Pragma "no-cache";
            add_header Expires "0";
        }
    }

    # --- app.granilink.com ---
    server {
        listen 443 ssl http2;
        server_name app.granilink.com;

        ssl_certificate     /etc/letsencrypt/live/app.granilink.com/fullchain.pem;
        ssl_certificate_key /etc/letsencrypt/live/app.granilink.com/privkey.pem;
        ssl_protocols TLSv1.2 TLSv1.3;
        ssl_ciphers ECDHE-RSA-AES256-GCM-SHA512:DHE-RSA-AES256-GCM-SHA512:ECDHE-RSA-AES256-GCM-SHA384:DHE-RSA-AES256-GCM-SHA384;
        ssl_prefer_server_ciphers off;
        ssl_session_cache shared:SSL:10m;
        ssl_session_timeout 10m;

        add_header X-Frame-Options SAMEORIGIN;
        add_header X-Content-Type-Options nosniff;
        add_header X-XSS-Protection "1; mode=block";
        add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;

        location /.well-known/acme-challenge/ {
            root /var/www/granivpn/static-pages;
            try_files $uri =404;
        }

        location / {
            proxy_pass https://gleaming-brioche-b0b809.netlify.app;
            proxy_set_header Host gleaming-brioche-b0b809.netlify.app;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto $scheme;
            proxy_ssl_verify off;
        }
    }
    # END GRANILINK CUTOVER
NGINX
echo "}" >> "$tmp"
mv "$tmp" "$CONF"

docker restart granivpn_nginx >/dev/null
docker exec granivpn_nginx nginx -t

for url in \
  https://granilink.com/ \
  https://admin.granilink.com/ \
  https://app.granilink.com/ \
  https://api.granilink.com/health; do
  echo "== $url =="
  curl -I -L --max-time 20 "$url" | sed -n '1,12p'
done
