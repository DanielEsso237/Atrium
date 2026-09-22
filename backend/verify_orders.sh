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

echo "== referentiel restaurant =="
OUTLET_ID=$(curl -s -X POST "$API/outlets" -H "$AUTH" -H "Content-Type: application/json" \
  -d "{\"code\":\"REST$TS\",\"label\":\"Restaurant\"}" | python3 -c "import sys,json;print(json.load(sys.stdin)['id'])")
STATION_ID=$(curl -s -X POST "$API/prep-stations" -H "$AUTH" -H "Content-Type: application/json" \
  -d "{\"code\":\"CUI$TS\",\"label\":\"Cuisine\"}" | python3 -c "import sys,json;print(json.load(sys.stdin)['id'])")
MENUCAT_ID=$(curl -s -X POST "$API/menu-categories" -H "$AUTH" -H "Content-Type: application/json" \
  -d "{\"outlet_id\":\"$OUTLET_ID\",\"label\":\"Plats\"}" | python3 -c "import sys,json;print(json.load(sys.stdin)['id'])")
ITEM_ID=$(curl -s -X POST "$API/menu-items" -H "$AUTH" -H "Content-Type: application/json" \
  -d "{\"code\":\"PLAT$TS\",\"label\":\"Poulet DG\",\"menu_category_id\":\"$MENUCAT_ID\",\"prep_station_id\":\"$STATION_ID\",\"price\":5000}" \
  | python3 -c "import sys,json;print(json.load(sys.stdin)['id'])")

echo "== commande sur place (ON_SITE) =="
CODE=$(curl -s -o /tmp/v_order.json -w "%{http_code}" -X POST "$API/orders" -H "$AUTH" -H "Content-Type: application/json" \
  -d "{\"outlet_id\":\"$OUTLET_ID\",\"type\":\"ON_SITE\",\"covers\":2,\"items\":[{\"menu_item_id\":\"$ITEM_ID\",\"quantity\":2}]}")
check "POST /orders" 201 "$CODE"
cat /tmp/v_order.json
echo
ORDER_ID=$(python3 -c "import json;print(json.load(open('/tmp/v_order.json'))['id'])")
TOTAL=$(python3 -c "import json;print(json.load(open('/tmp/v_order.json'))['total'])")
PREP_ID=$(python3 -c "import json;print(json.load(open('/tmp/v_order.json'))['items'][0]['prep_station_id'])")
echo "  total=$TOTAL (attendu 10000 = 2 x 5000), routage prep_station=$PREP_ID (attendu $STATION_ID)"
[ "$TOTAL" = "10000" ] && [ "$PREP_ID" = "$STATION_ID" ] && echo "  OK   montant et routage R1 corrects" || { echo "  FAIL montant ou routage"; FAIL=$((FAIL+1)); }

echo "== envoi puis service =="
CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$API/orders/$ORDER_ID/send" -H "$AUTH")
check "POST send" 200 "$CODE"
CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$API/orders/$ORDER_ID/serve" -H "$AUTH")
check "POST serve (ON_SITE, sans folio a debiter)" 200 "$CODE"

echo "== room service : chambre occupee, doit se reporter sur le folio =="
STD_ID=$(curl -s "$API/room-types" -H "$AUTH" | python3 -c "import sys,json; print([t['id'] for t in json.load(sys.stdin) if t['code']=='STD'][0])")
GUEST_ID=$(curl -s -X POST "$API/guests" -H "$AUTH" -H "Content-Type: application/json" -d '{"first_name":"Ines","last_name":"RoomService"}' | python3 -c "import sys,json;print(json.load(sys.stdin)['id'])")
RES=$(curl -s -X POST "$API/reservations" -H "$AUTH" -H "Content-Type: application/json" \
  -d "{\"guest_id\":\"$GUEST_ID\",\"rooms\":[{\"room_type_id\":\"$STD_ID\",\"arrival_date\":\"2027-04-01\",\"departure_date\":\"2027-04-02\"}]}")
RES_ID=$(echo "$RES" | python3 -c "import sys,json;print(json.load(sys.stdin)['id'])")
LINE_ID=$(echo "$RES" | python3 -c "import sys,json;print(json.load(sys.stdin)['rooms'][0]['id'])")
ROOM_ID=$(curl -s "$API/rooms" -H "$AUTH" | python3 -c "
import sys,json
rooms=json.load(sys.stdin)
print([r for r in rooms if r['room_type']['code']=='STD' and r['occupancy_status']=='VACANT'][0]['id'])
")
curl -s -X POST "$API/reservations/$RES_ID/rooms/$LINE_ID/check-in" -H "$AUTH" -H "Content-Type: application/json" -d "{\"room_id\":\"$ROOM_ID\"}" > /dev/null
FOLIO_ID=$(curl -s "$API/folios?guest_id=$GUEST_ID" -H "$AUTH" | python3 -c "import sys,json;print(json.load(sys.stdin)[0]['id'])")
BALANCE_BEFORE=$(curl -s "$API/folios/$FOLIO_ID" -H "$AUTH" | python3 -c "import sys,json;print(json.load(sys.stdin)['balance'])")

RS_ORDER=$(curl -s -X POST "$API/orders" -H "$AUTH" -H "Content-Type: application/json" \
  -d "{\"outlet_id\":\"$OUTLET_ID\",\"type\":\"ROOM_SERVICE\",\"room_id\":\"$ROOM_ID\",\"items\":[{\"menu_item_id\":\"$ITEM_ID\",\"quantity\":1}]}")
RS_ORDER_ID=$(echo "$RS_ORDER" | python3 -c "import sys,json;print(json.load(sys.stdin)['id'])")
curl -s -X POST "$API/orders/$RS_ORDER_ID/send" -H "$AUTH" > /dev/null
CODE=$(curl -s -o /tmp/v_rsserve.json -w "%{http_code}" -X POST "$API/orders/$RS_ORDER_ID/serve" -H "$AUTH")
check "POST serve (ROOM_SERVICE)" 200 "$CODE"
RS_FOLIO_ID=$(python3 -c "import json;print(json.load(open('/tmp/v_rsserve.json'))['folio_id'])")
echo "  folio_id sur la commande: $RS_FOLIO_ID (attendu $FOLIO_ID)"
[ "$RS_FOLIO_ID" = "$FOLIO_ID" ] && echo "  OK   commande rattachee au bon folio" || { echo "  FAIL mauvais folio"; FAIL=$((FAIL+1)); }

BALANCE_AFTER=$(curl -s "$API/folios/$FOLIO_ID" -H "$AUTH" | python3 -c "import sys,json;print(json.load(sys.stdin)['balance'])")
echo "  balance avant=$BALANCE_BEFORE, apres=$BALANCE_AFTER (doit avoir augmente de 5000)"
[ "$((BALANCE_AFTER - BALANCE_BEFORE))" = "5000" ] && echo "  OK   report automatique sur le folio (F3.6)" || { echo "  FAIL le report ne fait pas +5000"; FAIL=$((FAIL+1)); }

echo "== double check-in sur la MEME chambre depuis une autre reservation (409) =="
GUEST3_ID=$(curl -s -X POST "$API/guests" -H "$AUTH" -H "Content-Type: application/json" -d '{"first_name":"Autre","last_name":"MemeChambre"}' | python3 -c "import sys,json;print(json.load(sys.stdin)['id'])")
RES3=$(curl -s -X POST "$API/reservations" -H "$AUTH" -H "Content-Type: application/json" \
  -d "{\"guest_id\":\"$GUEST3_ID\",\"rooms\":[{\"room_type_id\":\"$STD_ID\",\"arrival_date\":\"2027-04-01\",\"departure_date\":\"2027-04-02\"}]}")
RES3_ID=$(echo "$RES3" | python3 -c "import sys,json;print(json.load(sys.stdin)['id'])")
LINE3_ID=$(echo "$RES3" | python3 -c "import sys,json;print(json.load(sys.stdin)['rooms'][0]['id'])")
CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$API/reservations/$RES3_ID/rooms/$LINE3_ID/check-in" \
  -H "$AUTH" -H "Content-Type: application/json" -d "{\"room_id\":\"$ROOM_ID\"}")
check "check-in chambre deja occupee par un autre sejour" 409 "$CODE"

echo "== room service sur chambre vacante refuse (422) =="
VACANT_ROOM=$(curl -s "$API/rooms" -H "$AUTH" | python3 -c "
import sys,json
rooms=json.load(sys.stdin)
print([r for r in rooms if r['id'] != '$ROOM_ID' and r['occupancy_status']=='VACANT'][0]['id'])
")
BADORDER=$(curl -s -X POST "$API/orders" -H "$AUTH" -H "Content-Type: application/json" \
  -d "{\"outlet_id\":\"$OUTLET_ID\",\"type\":\"ROOM_SERVICE\",\"room_id\":\"$VACANT_ROOM\",\"items\":[{\"menu_item_id\":\"$ITEM_ID\",\"quantity\":1}]}")
BADORDER_ID=$(echo "$BADORDER" | python3 -c "import sys,json;print(json.load(sys.stdin)['id'])")
curl -s -X POST "$API/orders/$BADORDER_ID/send" -H "$AUTH" > /dev/null
CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$API/orders/$BADORDER_ID/serve" -H "$AUTH")
check "serve room service sur chambre vacante" 422 "$CODE"

echo "== annulation apres service refusee (409) =="
CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$API/orders/$ORDER_ID/cancel" -H "$AUTH")
check "cancel apres serve" 409 "$CODE"

echo
echo "===================="
[ "$FAIL" -eq 0 ] && echo "Tout est bon (0 echec)." || echo "$FAIL echec(s) -- voir ci-dessus."
echo "===================="

echo "== erreurs serveur (hors bcrypt) =="
grep -i "error\|exception" /tmp/uvicorn.log | grep -v bcrypt | grep -v "_bcrypt\|_load_backend" | grep -v "^Traceback" || echo "aucune"
