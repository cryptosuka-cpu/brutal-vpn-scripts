#!/bin/bash
set -e

ADMIN_USER=${ADMIN_USER:-admin}
ADMIN_PASS=${ADMIN_PASS:-$(openssl rand -hex 12)}

echo "🚀 Brutal VPN Bootstrap starting..."
echo "👤 Admin: $ADMIN_USER"

# 1. Обновление системы
apt-get update -y -q
apt-get install -y -q curl socat python3 python3-pip

# Устанавливаем bcrypt для Python
pip3 install bcrypt --quiet --break-system-packages 2>/dev/null || pip3 install bcrypt --quiet

# 2. Установка Marzban
if [ ! -d "/opt/marzban" ]; then
    echo "📦 Installing Marzban..."
    bash -c "$(curl -sL https://github.com/Gozargah/Marzban-scripts/raw/master/marzban.sh)" @ install &
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

# Ждём пока БД создастся
DB_PATH="/var/lib/marzban/db.sqlite3"
echo "⏳ Waiting for database..."
for i in $(seq 1 20); do
    if [ -f "$DB_PATH" ]; then
        echo "✅ Database found!"
        break
    fi
    sleep 3
done

# 3. Создаём admin напрямую через SQLite + bcrypt
echo "👤 Creating admin in database..."
python3 << PYEOF
import sqlite3
import bcrypt
import sys

db_path = "/var/lib/marzban/db.sqlite3"
username = "$ADMIN_USER"
password = "$ADMIN_PASS"

try:
    # Генерируем bcrypt хеш
    hashed = bcrypt.hashpw(password.encode(), bcrypt.gensalt()).decode()
    
    conn = sqlite3.connect(db_path)
    cursor = conn.cursor()
    
    # Проверяем есть ли уже такой admin
    cursor.execute("SELECT id FROM admins WHERE username = ?", (username,))
    existing = cursor.fetchone()
    
    if existing:
        # Обновляем пароль
        cursor.execute("UPDATE admins SET hashed_password = ?, is_sudo = 1 WHERE username = ?", 
                      (hashed, username))
        print(f"✅ Admin '{username}' password updated")
    else:
        # Создаём нового
        cursor.execute("INSERT INTO admins (username, hashed_password, is_sudo) VALUES (?, ?, 1)",
                      (username, hashed, True))
        print(f"✅ Admin '{username}' created successfully")
    
    conn.commit()
    conn.close()
except Exception as e:
    print(f"❌ Error: {e}")
    sys.exit(1)
PYEOF

# Перезапускаем Marzban чтобы он подхватил нового admin
echo "🔄 Restarting Marzban..."
marzban restart > /dev/null 2>&1 || docker restart marzban-marzban-1 > /dev/null 2>&1
sleep 5

# 4. Получаем токен
echo "🔑 Getting auth token..."
TOKEN=""
for i in $(seq 1 10); do
    TOKEN=$(curl -s -X POST http://127.0.0.1:8000/api/admin/token \
      -H "Content-Type: application/x-www-form-urlencoded" \
      -d "username=$ADMIN_USER&password=$ADMIN_PASS" \
      | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('access_token',''))" 2>/dev/null || echo "")
    if [ -n "$TOKEN" ]; then
        echo "✅ Auth token received!"
        break
    fi
    sleep 3
done

# 5. Генерируем Reality ключи
echo "🔑 Generating Reality keys..."
KEYS=$(docker exec marzban-marzban-1 xray x25519 2>/dev/null)
PRIVATE=$(echo "$KEYS" | grep "Private" | awk '{print $3}')
PUBLIC=$(echo "$KEYS" | grep "Public" | awk '{print $3}')

# 6. Применяем Xray конфиг
echo "⚙️  Applying Xray config..."
if [ -n "$TOKEN" ] && [ -n "$PRIVATE" ]; then
    RESULT=$(curl -s -o /dev/null -w "%{http_code}" -X PUT http://127.0.0.1:8000/api/core/config \
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
      }")
    if [ "$RESULT" = "200" ]; then
        echo "✅ Xray config applied!"
    else
        echo "⚠️  Config apply returned $RESULT — вставь вручную"
    fi
else
    echo "⚠️  Вставь конфиг вручную в панели"
fi

# 7. Настраиваем socat
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
echo "🔍 Проверка API:"
echo "   curl http://$SERVER_IP:8080/api/health"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
