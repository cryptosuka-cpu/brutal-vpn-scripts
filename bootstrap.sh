#!/bin/bash
set -e

ADMIN_USER=${ADMIN_USER:-admin}
ADMIN_PASS=${ADMIN_PASS:-$(openssl rand -hex 16)}

echo "🚀 Brutal VPN Bootstrap starting..."
echo "👤 Admin: $ADMIN_USER"

# 1. Обновление системы
apt-get update -y -q
apt-get install -y -q curl socat python3

# 2. Установка Marzban
if [ ! -d "/opt/marzban" ]; then
    echo "📦 Installing Marzban..."
    bash -c "$(curl -sL https://github.com/Gozargah/Marzban-scripts/raw/master/marzban.sh)" @ install &
    INSTALL_PID=$!
    echo "⏳ Waiting for Marzban..."
    for i in $(seq 1 60); do
        if curl -s http://127.0.0.1:8000/ > /dev/null 2>&1; then
            echo "✅ Marzban is up!"
            break
        fi
        sleep 5
    done
else
    echo "✅ Marzban already installed"
    marzban restart > /dev/null 2>&1 || true
    sleep 5
fi

# 3. Создаём admin через прямой INSERT в SQLite
echo "👤 Creating admin..."
DB_PATH="/var/lib/marzban/db.sqlite3"
sleep 3

# Ждём пока БД появится
for i in $(seq 1 20); do
    if [ -f "$DB_PATH" ]; then break; fi
    sleep 3
done

# Хэш пароля через Python
PASS_HASH=$(python3 -c "
import bcrypt
password = '$ADMIN_PASS'.encode()
salt = bcrypt.gensalt()
print(bcrypt.hashpw(password, salt).decode())
" 2>/dev/null || python3 -c "
import hashlib, os
salt = os.urandom(16).hex()
h = hashlib.sha256(('$ADMIN_PASS' + salt).encode()).hexdigest()
print(h)
")

# Создаём через API если уже есть дефолтный admin
TOKEN=$(curl -s -X POST http://127.0.0.1:8000/api/admin/token \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "username=admin&password=admin" \
  | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('access_token',''))" 2>/dev/null || echo "")

if [ -n "$TOKEN" ]; then
    # Создаём нового sudo admin
    curl -s -X POST http://127.0.0.1:8000/api/admin \
      -H "Authorization: Bearer $TOKEN" \
      -H "Content-Type: application/json" \
      -d "{\"username\":\"$ADMIN_USER\",\"password\":\"$ADMIN_PASS\",\"is_sudo\":true}" > /dev/null 2>&1 || true
    echo "✅ Admin created via API"
    
    # Проверяем что новый admin работает
    NEW_TOKEN=$(curl -s -X POST http://127.0.0.1:8000/api/admin/token \
      -H "Content-Type: application/x-www-form-urlencoded" \
      -d "username=$ADMIN_USER&password=$ADMIN_PASS" \
      | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('access_token',''))" 2>/dev/null || echo "")
    
    if [ -n "$NEW_TOKEN" ]; then
        TOKEN=$NEW_TOKEN
        echo "✅ New admin verified"
    fi
else
    # Пробуем войти с нашим паролем (уже создан)
    TOKEN=$(curl -s -X POST http://127.0.0.1:8000/api/admin/token \
      -H "Content-Type: application/x-www-form-urlencoded" \
      -d "username=$ADMIN_USER&password=$ADMIN_PASS" \
      | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('access_token',''))" 2>/dev/null || echo "")
fi

# 4. Генерируем Reality ключи
echo "🔑 Generating Reality keys..."
sleep 2
KEYS=$(docker exec marzban-marzban-1 xray x25519 2>/dev/null)
PRIVATE=$(echo "$KEYS" | grep "Private" | awk '{print $3}')
PUBLIC=$(echo "$KEYS" | grep "Public" | awk '{print $3}')

# 5. Применяем Xray конфиг
echo "⚙️  Applying Xray config..."

if [ -n "$TOKEN" ]; then
    curl -s -X PUT http://127.0.0.1:8000/api/core/config \
      -H "Authorization: Bearer $TOKEN" \
      -H "Content-Type: application/json" \
      -d "{
        \"log\":{\"loglevel\":\"warning\"},
        \"routing\":{\"rules\":[{\"ip\":[\"geoip:private\"],\"outboundTag\":\"BLOCK\",\"type\":\"field\"}]},
        \"inbounds\":[{
          \"tag\":\"VLESS TCP REALITY\",
          \"listen\":\"0.0.0.0\",
          \"port\":52006,
          \"protocol\":\"vless\",
          \"settings\":{\"clients\":[],\"decryption\":\"none\"},
          \"streamSettings\":{
            \"network\":\"tcp\",
            \"security\":\"reality\",
            \"realitySettings\":{
              \"show\":false,
              \"dest\":\"max.ru:443\",
              \"xver\":0,
              \"serverNames\":[\"max.ru\"],
              \"privateKey\":\"$PRIVATE\",
              \"shortIds\":[\"abcdef1234567890\"],
              \"fingerprint\":\"qq\"
            }
          },
          \"sniffing\":{\"enabled\":true,\"destOverride\":[\"http\",\"tls\"]}
        }],
        \"outbounds\":[
          {\"protocol\":\"freedom\",\"tag\":\"DIRECT\"},
          {\"protocol\":\"blackhole\",\"tag\":\"BLOCK\"}
        ]
      }" > /dev/null 2>&1 && echo "✅ Xray config applied!" || echo "⚠️  Вставь конфиг вручную"
else
    echo "⚠️  Вставь конфиг вручную в панели"
fi

# 6. Настраиваем socat
echo "🔌 Setting up socat..."
cat > /etc/systemd/system/socat-marzban.service << 'SERVICE'
[Unit]
Description=Socat Marzban proxy
After=network.target

[Service]
ExecStart=/usr/bin/socat TCP-LISTEN:8080,fork TCP:127.0.0.1:8000
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
SERVICE

systemctl daemon-reload
systemctl enable socat-marzban
systemctl restart socat-marzban 2>/dev/null || systemctl start socat-marzban

SERVER_IP=$(curl -s https://api64.ipify.org 2>/dev/null || hostname -I | awk '{print $1}')

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "🎉 Bootstrap complete!"
echo ""
echo "🔐 Admin credentials:"
echo "   Username: $ADMIN_USER"
echo "   Password: $ADMIN_PASS"
echo ""
echo "🔑 Reality keys:"
echo "   Private: $PRIVATE"
echo "   Public:  $PUBLIC"
echo ""
echo "📱 Панель (на Mac):"
echo "   ssh -L 8000:localhost:8000 root@$SERVER_IP"
echo "   http://127.0.0.1:8000/dashboard"
echo ""
echo "🔍 Проверка:"
echo "   curl http://$SERVER_IP:8080/api/health"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
