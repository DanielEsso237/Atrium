#!/bin/bash
set -e
cd "$(dirname "$0")"
. .venv/bin/activate

python3 -m app.db.seed

pkill -f "uvicorn app.main" 2>/dev/null || true
sleep 1
(uvicorn app.main:app --host 127.0.0.1 --port 8000 > /tmp/uvicorn.log 2>&1 &)
sleep 3

API="http://127.0.0.1:8000/api/v1"
FAIL=0
check() {
  local desc="$1" expected="$2" got="$3"
  if [ "$got" = "$expected" ]; then echo "  OK   $desc ($got)"; else echo "  FAIL $desc (attendu $expected, recu $got)"; FAIL=$((FAIL+1)); fi
}

TOKEN=$(curl -s -X POST "$API/auth/login" -H "Content-Type: application/json" \
  -d '{"employee_code":"ADMIN01","password":"ChangeMe123!"}' | python3 -c "import sys,json;print(json.load(sys.stdin)['access_token'])")
AUTH="Authorization: Bearer $TOKEN"

echo "== dashboard : releve de reference (peu importe ce qui tourne deja) =="
curl -s "$API/dashboard/summary" -H "$AUTH" -o /tmp/v_dash0.json
cat /tmp/v_dash0.json
echo
OCC_BEFORE=$(python3 -c "import json;print(json.load(open('/tmp/v_dash0.json'))['occupancy']['occupied_rooms'])")
REV_BEFORE=$(python3 -c "import json;print(json.load(open('/tmp/v_dash0.json'))['today_revenue_total'])")
CLEAN_BEFORE=$(python3 -c "import json;print(json.load(open('/tmp/v_dash0.json'))['rooms_to_clean'])")

TODAY=$(python3 -c "import datetime; print(datetime.date.today().isoformat())")

echo "== une arrivee aujourd'hui =="
STD_ID=$(curl -s "$API/room-types" -H "$AUTH" | python3 -c "import sys,json; print([t['id'] for t in json.load(sys.stdin) if t['code']=='STD'][0])")
GUEST_ID=$(curl -s -X POST "$API/guests" -H "$AUTH" -H "Content-Type: application/json" -d '{"first_name":"Test","last_name":"Dashboard"}' | python3 -c "import sys,json;print(json.load(sys.stdin)['id'])")
TOMORROW=$(python3 -c "import datetime; print((datetime.date.today()+datetime.timedelta(days=1)).isoformat())")
RES=$(curl -s -X POST "$API/reservations" -H "$AUTH" -H "Content-Type: application/json" \
  -d "{\"guest_id\":\"$GUEST_ID\",\"rooms\":[{\"room_type_id\":\"$STD_ID\",\"arrival_date\":\"$TODAY\",\"departure_date\":\"$TOMORROW\"}]}")
RES_ID=$(echo "$RES" | python3 -c "import sys,json;print(json.load(sys.stdin)['id'])")
LINE_ID=$(echo "$RES" | python3 -c "import sys,json;print(json.load(sys.stdin)['rooms'][0]['id'])")

curl -s "$API/dashboard/summary" -H "$AUTH" -o /tmp/v_dash1.json
ARR1=$(python3 -c "import json;print(json.load(open('/tmp/v_dash1.json'))['arrivals_today'])")
[ "$ARR1" -ge 1 ] && echo "  OK   arrivals_today a bien augmente ($ARR1)" || { echo "  FAIL arrivals_today ($ARR1)"; FAIL=$((FAIL+1)); }

echo "== check-in : occupation et CA jour doivent augmenter exactement de 1 chambre / 25000 =="
ROOM_ID=$(curl -s "$API/rooms" -H "$AUTH" | python3 -c "
import sys,json
print([r for r in json.load(sys.stdin) if r['room_type']['code']=='STD' and r['occupancy_status']=='VACANT'][0]['id'])
")
curl -s -X POST "$API/reservations/$RES_ID/rooms/$LINE_ID/check-in" -H "$AUTH" -H "Content-Type: application/json" \
  -d "{\"room_id\":\"$ROOM_ID\"}" > /dev/null
FOLIO_ID=$(curl -s "$API/folios?guest_id=$GUEST_ID" -H "$AUTH" | python3 -c "import sys,json;print(json.load(sys.stdin)[0]['id'])")
curl -s -X POST "$API/folios/$FOLIO_ID/post-stay-nights" -H "$AUTH" > /dev/null

curl -s "$API/dashboard/summary" -H "$AUTH" -o /tmp/v_dash2.json
cat /tmp/v_dash2.json
echo
OCC_AFTER=$(python3 -c "import json;print(json.load(open('/tmp/v_dash2.json'))['occupancy']['occupied_rooms'])")
REV_AFTER=$(python3 -c "import json;print(json.load(open('/tmp/v_dash2.json'))['today_revenue_total'])")
check "occupied_rooms : +1" "$((OCC_BEFORE + 1))" "$OCC_AFTER"
check "today_revenue_total : +25000 (1 nuit STD)" "$((REV_BEFORE + 25000))" "$REV_AFTER"

echo "== une tache de menage aujourd'hui : rooms_to_clean +1 =="
curl -s -X POST "$API/housekeeping-tasks" -H "$AUTH" -H "Content-Type: application/json" \
  -d "{\"room_id\":\"$ROOM_ID\",\"type\":\"REFRESH\",\"business_date\":\"$TODAY\"}" > /dev/null
curl -s "$API/dashboard/summary" -H "$AUTH" -o /tmp/v_dash3.json
CLEAN_AFTER=$(python3 -c "import json;print(json.load(open('/tmp/v_dash3.json'))['rooms_to_clean'])")
check "rooms_to_clean : +1" "$((CLEAN_BEFORE + 1))" "$CLEAN_AFTER"

echo
echo "===================="
[ "$FAIL" -eq 0 ] && echo "Tout est bon (0 echec)." || echo "$FAIL echec(s) -- voir ci-dessus."
echo "===================="

echo "== erreurs serveur (hors bcrypt) =="
grep -i "error\|exception" /tmp/uvicorn.log | grep -v bcrypt | grep -v "_bcrypt\|_load_backend" | grep -v "^Traceback" || echo "aucune"
