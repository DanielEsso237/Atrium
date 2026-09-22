#!/bin/bash
cd "$(dirname "$0")" 2>/dev/null

ROOT="http://127.0.0.1:8000"
API="$ROOT/api/v1"
PASS=0
FAIL=0

check() {
  local desc="$1" expected="$2" got="$3"
  if [ "$got" = "$expected" ]; then
    echo "  OK   $desc ($got)"
    PASS=$((PASS+1))
  else
    echo "  FAIL $desc (attendu $expected, recu $got)"
    FAIL=$((FAIL+1))
  fi
}

echo "== seed =="
python3 -m app.db.seed 2>&1 | tail -1

echo "== (re)demarrage du serveur =="
pkill -f "uvicorn app.main" 2>/dev/null
sleep 1
nohup uvicorn app.main:app --host 127.0.0.1 --port 8000 > /tmp/uvicorn.log 2>&1 &
sleep 3

echo "== sante =="
CODE=$(curl -s -o /dev/null -w "%{http_code}" "$ROOT/healthz")
check "GET /healthz" 200 "$CODE"

echo "== auth =="
curl -s -X POST "$API/auth/login" -H "Content-Type: application/json" \
  -d '{"employee_code":"ADMIN01","password":"ChangeMe123!"}' -o /tmp/v_login.json \
  -w "%{http_code}" > /tmp/v_login_code.txt
check "POST /auth/login (admin)" 200 "$(cat /tmp/v_login_code.txt)"
TOKEN=$(python3 -c "import json;print(json.load(open('/tmp/v_login.json')).get('access_token',''))" 2>/dev/null)
AUTH="Authorization: Bearer $TOKEN"

CODE=$(curl -s -o /dev/null -w "%{http_code}" "$API/auth/me" -H "$AUTH")
check "GET /auth/me" 200 "$CODE"

echo "== personnel =="
CODE=$(curl -s -o /dev/null -w "%{http_code}" "$API/roles" -H "$AUTH")
check "GET /roles" 200 "$CODE"
CODE=$(curl -s -o /dev/null -w "%{http_code}" "$API/users" -H "$AUTH")
check "GET /users" 200 "$CODE"

TS=$(date +%s)
CODE=$(curl -s -o /tmp/v_user.json -w "%{http_code}" -X POST "$API/users" -H "$AUTH" -H "Content-Type: application/json" \
  -d "{\"employee_code\":\"VERIF-U$TS\",\"first_name\":\"Test\",\"last_name\":\"Verif\",\"password\":\"Verif1234!\",\"role_codes\":[\"RECEPTION\"]}")
check "POST /users (creation)" 201 "$CODE"

echo "== clients =="
CODE=$(curl -s -o /dev/null -w "%{http_code}" "$API/guests" -H "$AUTH")
check "GET /guests" 200 "$CODE"
CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$API/guests" -H "$AUTH" -H "Content-Type: application/json" \
  -d "{\"first_name\":\"Test\",\"last_name\":\"Verif$TS\"}")
check "POST /guests (creation)" 201 "$CODE"

echo "== types de chambres =="
CODE=$(curl -s -o /dev/null -w "%{http_code}" "$API/room-types" -H "$AUTH")
check "GET /room-types" 200 "$CODE"
CODE=$(curl -s -o /tmp/v_rt.json -w "%{http_code}" -X POST "$API/room-types" -H "$AUTH" -H "Content-Type: application/json" \
  -d "{\"code\":\"VER$TS\",\"label\":\"Verif\",\"default_rate\":1000}")
check "POST /room-types (creation)" 201 "$CODE"
RT_ID=$(python3 -c "import json;print(json.load(open('/tmp/v_rt.json')).get('id',''))" 2>/dev/null)

echo "== chambres =="
CODE=$(curl -s -o /dev/null -w "%{http_code}" "$API/rooms" -H "$AUTH")
check "GET /rooms" 200 "$CODE"
CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$API/rooms" -H "$AUTH" -H "Content-Type: application/json" \
  -d "{\"number\":\"VERIF$TS\",\"room_type_id\":\"$RT_ID\"}")
check "POST /rooms (creation)" 201 "$CODE"

echo "== RBAC croise (receptionniste) =="
curl -s -X POST "$API/auth/login" -H "Content-Type: application/json" \
  -d "{\"employee_code\":\"VERIF-U$TS\",\"password\":\"Verif1234!\"}" -o /tmp/v_login2.json
RTOKEN=$(python3 -c "import json;print(json.load(open('/tmp/v_login2.json')).get('access_token',''))" 2>/dev/null)
RAUTH="Authorization: Bearer $RTOKEN"

CODE=$(curl -s -o /dev/null -w "%{http_code}" "$API/rooms" -H "$RAUTH")
check "receptionniste: GET /rooms" 200 "$CODE"
CODE=$(curl -s -o /dev/null -w "%{http_code}" "$API/users" -H "$RAUTH")
check "receptionniste: GET /users (doit etre refuse)" 403 "$CODE"
CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$API/room-types" -H "$RAUTH" -H "Content-Type: application/json" \
  -d '{"code":"X","label":"X","default_rate":0}')
check "receptionniste: POST /room-types (doit etre refuse)" 403 "$CODE"

echo "== sans token =="
CODE=$(curl -s -o /dev/null -w "%{http_code}" "$API/rooms")
check "GET /rooms sans token (doit etre refuse)" 401 "$CODE"

echo
echo "===================="
echo "  $PASS reussis, $FAIL echoues"
echo "===================="
[ "$FAIL" -eq 0 ] && echo "Tout est bon." || echo "Regarde les FAIL ci-dessus."
