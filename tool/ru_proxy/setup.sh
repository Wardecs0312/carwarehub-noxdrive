#!/usr/bin/env bash
# Посредник для мастеров из России: nginx на российском VPS пересылает все запросы программы
# (вход, база, файлы, функции, realtime) на Supabase. Россия режет скорость к Cloudflare, на котором
# стоит Supabase, а до российского сервера — нет.
#
# Запуск на чистом Ubuntu 24.04 под root:  bash setup.sh <ip-адрес сервера>
# Адрес для программы: https://<ip-через-дефисы>.sslip.io (бесплатный домен на IP, сертификат Let's Encrypt).
set -euo pipefail
IP="$1"
HOST="${IP//./-}.sslip.io"
UPSTREAM="qpfuosdqjcfbcubsmvrb.supabase.co"

export DEBIAN_FRONTEND=noninteractive
apt-get update -q
apt-get install -yq nginx certbot python3-certbot-nginx ufw

cat > /etc/nginx/sites-available/nox <<EOF
map \$http_upgrade \$connection_upgrade { default upgrade; '' close; }

server {
    listen 80;
    server_name $HOST;

    location / {
        proxy_pass https://$UPSTREAM;
        proxy_ssl_server_name on;
        proxy_ssl_name $UPSTREAM;
        proxy_set_header Host $UPSTREAM;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_http_version 1.1;
        # realtime (websocket)
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;
        # большие файлы идут потоком, без промежуточной записи на диск
        proxy_buffering off;
        proxy_request_buffering off;
        client_max_body_size 0;
        proxy_read_timeout 600s;
        proxy_send_timeout 600s;
    }

    # установщик программы для мастеров из России
    location /download/ {
        alias /var/www/nox-download/;
        autoindex off;
    }
}
EOF
mkdir -p /var/www/nox-download
ln -sf /etc/nginx/sites-available/nox /etc/nginx/sites-enabled/nox
rm -f /etc/nginx/sites-enabled/default
nginx -t
systemctl reload nginx

ufw allow OpenSSH
ufw allow 'Nginx Full'
ufw --force enable

certbot --nginx -d "$HOST" --non-interactive --agree-tos --register-unsafely-without-email --redirect
systemctl reload nginx
echo "Готово: https://$HOST"
