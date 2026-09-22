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
TS=$(date +%s)
FAIL=0
check() {
  local desc="$1" expected="$2" got="$3"
  if [ "$got" = "$expected" ]; then echo "  OK   $desc ($got)"; else echo "  FAIL $desc (attendu $expected, recu $got)"; FAIL=$((FAIL+1)); fi
}

TOKEN=$(curl -s -X POST "$API/auth/login" -H "Content-Type: application/json" \
  -d '{"employee_code":"ADMIN01","password":"ChangeMe123!"}' | python3 -c "import sys,json;print(json.load(sys.stdin)['access_token'])")
AUTH="Authorization: Bearer $TOKEN"

ROOM_ID=$(curl -s "$API/rooms" -H "$AUTH" | python3 -c "import sys,json; print(json.load(sys.stdin)[0]['id'])")

echo "== housekeeping : cycle complet =="
TASK=$(curl -s -X POST "$API/housekeeping-tasks" -H "$AUTH" -H "Content-Type: application/json" \
  -d "{\"room_id\":\"$ROOM_ID\",\"type\":\"DEPARTURE\",\"business_date\":\"2027-01-01\"}")
TASK_ID=$(echo "$TASK" | python3 -c "import sys,json;print(json.load(sys.stdin)['id'])")
TASK_STATUS=$(echo "$TASK" | python3 -c "import sys,json;print(json.load(sys.stdin)['status'])")
check "creation tache (PENDING)" "PENDING" "$TASK_STATUS"

curl -s -X POST "$API/housekeeping-tasks/$TASK_ID/assign" -H "$AUTH" -H "Content-Type: application/json" \
  -d "{\"user_id\":\"01920000-0000-7000-8000-000000050001\"}" > /dev/null

curl -s -X POST "$API/housekeeping-tasks/$TASK_ID/start" -H "$AUTH" > /dev/null
ROOM_HK=$(curl -s "$API/rooms" -H "$AUTH" | python3 -c "
import sys,json
r=[x for x in json.load(sys.stdin) if x['id']=='$ROOM_ID'][0]
print(r['housekeeping_status'])
")
check "chambre passee IN_PROGRESS au demarrage" "IN_PROGRESS" "$ROOM_HK"

sleep 1
curl -s -X POST "$API/housekeeping-tasks/$TASK_ID/finish" -H "$AUTH" -o /tmp/v_finish.json
DURATION=$(python3 -c "import json;print(json.load(open('/tmp/v_finish.json'))['duration_minutes'])")
echo "  duration_minutes=$DURATION (>= 0 attendu)"
ROOM_HK2=$(curl -s "$API/rooms" -H "$AUTH" | python3 -c "
import sys,json
r=[x for x in json.load(sys.stdin) if x['id']=='$ROOM_ID'][0]
print(r['housekeeping_status'])
")
check "chambre passee CLEAN a la fin" "CLEAN" "$ROOM_HK2"

curl -s -X POST "$API/housekeeping-tasks/$TASK_ID/inspect" -H "$AUTH" > /dev/null
ROOM_HK3=$(curl -s "$API/rooms" -H "$AUTH" | python3 -c "
import sys,json
r=[x for x in json.load(sys.stdin) if x['id']=='$ROOM_ID'][0]
print(r['housekeeping_status'])
")
check "chambre passee INSPECTED apres inspection" "INSPECTED" "$ROOM_HK3"

echo "== maintenance : ticket bloquant, resolution, reouverture chambre =="
TICKET=$(curl -s -X POST "$API/maintenance-tickets" -H "$AUTH" -H "Content-Type: application/json" \
  -d "{\"room_id\":\"$ROOM_ID\",\"title\":\"Fuite salle de bain\",\"priority\":\"URGENT\",\"blocks_room\":true}")
TICKET_ID=$(echo "$TICKET" | python3 -c "import sys,json;print(json.load(sys.stdin)['id'])")
ROOM_OOO=$(curl -s "$API/rooms" -H "$AUTH" | python3 -c "
import sys,json
r=[x for x in json.load(sys.stdin) if x['id']=='$ROOM_ID'][0]
print(r['is_out_of_order'])
")
check "chambre hors service a l'ouverture du ticket bloquant" "True" "$ROOM_OOO"

curl -s -X POST "$API/maintenance-tickets/$TICKET_ID/assign" -H "$AUTH" -H "Content-Type: application/json" \
  -d "{\"user_id\":\"01920000-0000-7000-8000-000000050001\"}" > /dev/null
curl -s -X POST "$API/maintenance-tickets/$TICKET_ID/interventions" -H "$AUTH" -H "Content-Type: application/json" \
  -d '{"description":"Remplacement joint","cost":5000}' > /dev/null
curl -s -X POST "$API/maintenance-tickets/$TICKET_ID/resolve" -H "$AUTH" -H "Content-Type: application/json" \
  -d '{"resolution":"Joint remplace, teste sans fuite."}' > /dev/null
CODE=$(curl -s -o /tmp/v_close.json -w "%{http_code}" -X POST "$API/maintenance-tickets/$TICKET_ID/close" -H "$AUTH")
check "POST close ticket" 200 "$CODE"
COST=$(python3 -c "import json;print(json.load(open('/tmp/v_close.json'))['cost'])")
check "cout cumule des interventions" 5000 "$COST"

ROOM_OOO2=$(curl -s "$API/rooms" -H "$AUTH" | python3 -c "
import sys,json
r=[x for x in json.load(sys.stdin) if x['id']=='$ROOM_ID'][0]
print(r['is_out_of_order'])
")
check "chambre remise en service a la cloture" "False" "$ROOM_OOO2"

echo "== stock : entree, sortie, refus si insuffisant, transfert =="
SUP_ID=$(curl -s -X POST "$API/suppliers" -H "$AUTH" -H "Content-Type: application/json" \
  -d "{\"code\":\"SUP$TS\",\"name\":\"Fournisseur\"}" | python3 -c "import sys,json;print(json.load(sys.stdin)['id'])")
PROD_ID=$(curl -s -X POST "$API/products" -H "$AUTH" -H "Content-Type: application/json" \
  -d "{\"reference\":\"REF$TS\",\"label\":\"Eau minerale 50cl\",\"default_supplier_id\":\"$SUP_ID\"}" | python3 -c "import sys,json;print(json.load(sys.stdin)['id'])")
LOC1_ID=$(curl -s -X POST "$API/stock-locations" -H "$AUTH" -H "Content-Type: application/json" \
  -d "{\"code\":\"ECO$TS\",\"label\":\"Economat\"}" | python3 -c "import sys,json;print(json.load(sys.stdin)['id'])")
LOC2_ID=$(curl -s -X POST "$API/stock-locations" -H "$AUTH" -H "Content-Type: application/json" \
  -d "{\"code\":\"MB$TS\",\"label\":\"Minibar etage 1\"}" | python3 -c "import sys,json;print(json.load(sys.stdin)['id'])")

curl -s -X POST "$API/stock-movements" -H "$AUTH" -H "Content-Type: application/json" \
  -d "{\"product_id\":\"$PROD_ID\",\"stock_location_id\":\"$LOC1_ID\",\"type\":\"IN\",\"quantity\":50}" > /dev/null
QTY1=$(curl -s "$API/stock-levels?stock_location_id=$LOC1_ID&product_id=$PROD_ID" -H "$AUTH" | python3 -c "import sys,json;print(json.load(sys.stdin)[0]['quantity'])")
check "quantite apres entree de 50" 50 "$QTY1"

CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$API/stock-movements" -H "$AUTH" -H "Content-Type: application/json" \
  -d "{\"product_id\":\"$PROD_ID\",\"stock_location_id\":\"$LOC1_ID\",\"type\":\"OUT\",\"quantity\":200}")
check "sortie superieure au stock disponible (409)" 409 "$CODE"

curl -s -X POST "$API/stock-movements" -H "$AUTH" -H "Content-Type: application/json" \
  -d "{\"product_id\":\"$PROD_ID\",\"stock_location_id\":\"$LOC1_ID\",\"type\":\"TRANSFER\",\"quantity\":20,\"counterpart_location_id\":\"$LOC2_ID\"}" > /dev/null
QTY1B=$(curl -s "$API/stock-levels?stock_location_id=$LOC1_ID&product_id=$PROD_ID" -H "$AUTH" | python3 -c "import sys,json;print(json.load(sys.stdin)[0]['quantity'])")
QTY2=$(curl -s "$API/stock-levels?stock_location_id=$LOC2_ID&product_id=$PROD_ID" -H "$AUTH" | python3 -c "import sys,json;print(json.load(sys.stdin)[0]['quantity'])")
echo "  apres transfert de 20: economat=$QTY1B (attendu 30), minibar=$QTY2 (attendu 20)"
[ "$QTY1B" = "30" ] && [ "$QTY2" = "20" ] && echo "  OK   transfert equilibre" || { echo "  FAIL transfert desequilibre"; FAIL=$((FAIL+1)); }

echo
echo "===================="
[ "$FAIL" -eq 0 ] && echo "Tout est bon (0 echec)." || echo "$FAIL echec(s) -- voir ci-dessus."
echo "===================="

echo "== erreurs serveur (hors bcrypt) =="
grep -i "error\|exception" /tmp/uvicorn.log | grep -v bcrypt | grep -v "_bcrypt\|_load_backend" | grep -v "^Traceback" || echo "aucune"
