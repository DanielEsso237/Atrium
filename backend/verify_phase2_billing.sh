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

STD_ID=$(curl -s "$API/room-types" -H "$AUTH" | python3 -c "import sys,json; print([t['id'] for t in json.load(sys.stdin) if t['code']=='STD'][0])")
GUEST_ID=$(curl -s -X POST "$API/guests" -H "$AUTH" -H "Content-Type: application/json" \
  -d '{"first_name":"Awa","last_name":"Facture"}' | python3 -c "import sys,json;print(json.load(sys.stdin)['id'])")

echo "== reservation + check-in =="
RES=$(curl -s -X POST "$API/reservations" -H "$AUTH" -H "Content-Type: application/json" \
  -d "{\"guest_id\":\"$GUEST_ID\",\"rooms\":[{\"room_type_id\":\"$STD_ID\",\"arrival_date\":\"2027-03-01\",\"departure_date\":\"2027-03-03\"}]}")
RES_ID=$(echo "$RES" | python3 -c "import sys,json;print(json.load(sys.stdin)['id'])")
LINE_ID=$(echo "$RES" | python3 -c "import sys,json;print(json.load(sys.stdin)['rooms'][0]['id'])")
ROOM_ID=$(curl -s "$API/rooms" -H "$AUTH" | python3 -c "
import sys,json
rooms=json.load(sys.stdin)
print([r for r in rooms if r['room_type']['code']=='STD' and r['occupancy_status']=='VACANT'][0]['id'])
")

curl -s -X POST "$API/reservations/$RES_ID/rooms/$LINE_ID/check-in" -H "$AUTH" -H "Content-Type: application/json" \
  -d "{\"room_id\":\"$ROOM_ID\"}" > /dev/null

echo "== folio auto-cree au check-in =="
FOLIO=$(curl -s "$API/folios?guest_id=$GUEST_ID" -H "$AUTH")
echo "$FOLIO"
FOLIO_ID=$(echo "$FOLIO" | python3 -c "import sys,json;print(json.load(sys.stdin)[0]['id'])")
FOLIO_STATUS=$(echo "$FOLIO" | python3 -c "import sys,json;print(json.load(sys.stdin)[0]['status'])")
[ "$FOLIO_STATUS" = "OPEN" ] && echo "  OK   folio ouvert automatiquement" || { echo "  FAIL folio non cree"; FAIL=$((FAIL+1)); }

echo "== poser les nuitees sur le folio =="
CODE=$(curl -s -o /tmp/v_folio1.json -w "%{http_code}" -X POST "$API/folios/$FOLIO_ID/post-stay-nights" -H "$AUTH")
check "POST post-stay-nights" 200 "$CODE"
CHARGES=$(python3 -c "import json;print(json.load(open('/tmp/v_folio1.json'))['charges_total'])")
echo "  charges_total=$CHARGES (attendu 50000 = 2 nuits x 25000)"
[ "$CHARGES" = "50000" ] && echo "  OK   charges_total correct" || { echo "  FAIL charges_total"; FAIL=$((FAIL+1)); }

echo "== charge manuelle : minibar =="
CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$API/folios/$FOLIO_ID/items" -H "$AUTH" -H "Content-Type: application/json" \
  -d '{"category":"MINIBAR","label":"Eau + soda","quantity":2,"unit_price":1000}')
check "POST folio item (minibar)" 201 "$CODE"

echo "== remise SANS folio.discount refusee (403) -- simulee via role reception =="
RCODE=$(curl -s -X POST "$API/users" -H "$AUTH" -H "Content-Type: application/json" \
  -d "{\"employee_code\":\"RECBILL$(date +%s)\",\"first_name\":\"R\",\"last_name\":\"B\",\"password\":\"Test1234!\",\"role_codes\":[\"RECEPTION\"]}")
REMP_CODE=$(echo "$RCODE" | python3 -c "import sys,json;print(json.load(sys.stdin)['employee_code'])")
RTOKEN=$(curl -s -X POST "$API/auth/login" -H "Content-Type: application/json" \
  -d "{\"employee_code\":\"$REMP_CODE\",\"password\":\"Test1234!\"}" | python3 -c "import sys,json;print(json.load(sys.stdin)['access_token'])")
CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$API/folios/$FOLIO_ID/items" -H "Authorization: Bearer $RTOKEN" -H "Content-Type: application/json" \
  -d '{"category":"DISCOUNT","label":"Geste commercial","quantity":1,"unit_price":5000}')
check "reception seule: POST discount (doit etre refuse)" 403 "$CODE"

echo "== remise AVEC folio.discount (via ADMIN, qui a tout) =="
CODE=$(curl -s -o /tmp/v_disc.json -w "%{http_code}" -X POST "$API/folios/$FOLIO_ID/items" -H "$AUTH" -H "Content-Type: application/json" \
  -d '{"category":"DISCOUNT","label":"Geste commercial","quantity":1,"unit_price":2000}')
check "admin: POST discount" 201 "$CODE"

BALANCE_BEFORE=$(curl -s "$API/folios/$FOLIO_ID" -H "$AUTH" | python3 -c "import sys,json;print(json.load(sys.stdin)['balance'])")
echo "  balance avant paiement: $BALANCE_BEFORE (attendu 50000 = 50000+2000-2000)"
[ "$BALANCE_BEFORE" = "50000" ] && echo "  OK   la remise reduit bien le solde" || { echo "  FAIL la remise n'a pas reduit le solde"; FAIL=$((FAIL+1)); }

echo "== paiement integral =="
CODE=$(curl -s -o /tmp/v_pay.json -w "%{http_code}" -X POST "$API/folios/$FOLIO_ID/payments" -H "$AUTH" -H "Content-Type: application/json" \
  -d "{\"method\":\"CASH\",\"amount\":$BALANCE_BEFORE}")
check "POST payment" 201 "$CODE"
BALANCE_AFTER=$(python3 -c "import json;print(json.load(open('/tmp/v_pay.json'))['balance'])")
echo "  balance apres paiement: $BALANCE_AFTER (attendu 0)"
[ "$BALANCE_AFTER" = "0" ] && echo "  OK   solde nul apres paiement integral" || { echo "  FAIL solde non nul"; FAIL=$((FAIL+1)); }

echo "== cloture du folio =="
CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$API/folios/$FOLIO_ID/close" -H "$AUTH")
check "POST close (solde nul)" 200 "$CODE"

echo "== facture =="
CODE=$(curl -s -o /tmp/v_inv.json -w "%{http_code}" -X POST "$API/folios/$FOLIO_ID/invoice" -H "$AUTH")
check "POST invoice" 201 "$CODE"
cat /tmp/v_inv.json
echo
INV_NUMBER=$(python3 -c "import json;print(json.load(open('/tmp/v_inv.json'))['number'])")
INV_PROVISIONAL=$(python3 -c "import json;print(json.load(open('/tmp/v_inv.json'))['is_provisional'])")
echo "  numero=$INV_NUMBER provisional=$INV_PROVISIONAL (attendu un numero FA-xxxxxx et False)"
[ "$INV_PROVISIONAL" = "False" ] && echo "  OK   numero legal definitif" || { echo "  FAIL facture provisoire"; FAIL=$((FAIL+1)); }

echo "== 2e facture, verification que la sequence avance =="
GUEST2_ID=$(curl -s -X POST "$API/guests" -H "$AUTH" -H "Content-Type: application/json" -d '{"first_name":"Autre","last_name":"Client"}' | python3 -c "import sys,json;print(json.load(sys.stdin)['id'])")
RES2=$(curl -s -X POST "$API/reservations" -H "$AUTH" -H "Content-Type: application/json" \
  -d "{\"guest_id\":\"$GUEST2_ID\",\"rooms\":[{\"room_type_id\":\"$STD_ID\",\"arrival_date\":\"2027-03-05\",\"departure_date\":\"2027-03-06\"}]}")
RES2_ID=$(echo "$RES2" | python3 -c "import sys,json;print(json.load(sys.stdin)['id'])")
LINE2_ID=$(echo "$RES2" | python3 -c "import sys,json;print(json.load(sys.stdin)['rooms'][0]['id'])")
ROOM2_ID=$(curl -s "$API/rooms" -H "$AUTH" | python3 -c "
import sys,json
rooms=json.load(sys.stdin)
print([r for r in rooms if r['room_type']['code']=='STD' and r['occupancy_status']=='VACANT'][0]['id'])
")
curl -s -X POST "$API/reservations/$RES2_ID/rooms/$LINE2_ID/check-in" -H "$AUTH" -H "Content-Type: application/json" -d "{\"room_id\":\"$ROOM2_ID\"}" > /dev/null
FOLIO2_ID=$(curl -s "$API/folios?guest_id=$GUEST2_ID" -H "$AUTH" | python3 -c "import sys,json;print(json.load(sys.stdin)[0]['id'])")
curl -s -X POST "$API/folios/$FOLIO2_ID/post-stay-nights" -H "$AUTH" > /dev/null
INV2=$(curl -s -X POST "$API/folios/$FOLIO2_ID/invoice" -H "$AUTH")
INV2_NUMBER=$(echo "$INV2" | python3 -c "import sys,json;print(json.load(sys.stdin)['number'])")
echo "  1ere facture: $INV_NUMBER, 2e facture: $INV2_NUMBER (doivent etre consecutives)"
[ "$INV_NUMBER" != "$INV2_NUMBER" ] && echo "  OK   numeros distincts" || { echo "  FAIL meme numero !"; FAIL=$((FAIL+1)); }

echo "== nettoyage : check-out des deux sejours (pour ne pas polluer les scripts suivants) =="
curl -s -o /dev/null -X POST "$API/reservations/$RES_ID/rooms/$LINE_ID/check-out" -H "$AUTH"
curl -s -o /dev/null -X POST "$API/reservations/$RES2_ID/rooms/$LINE2_ID/check-out" -H "$AUTH"

echo
echo "===================="
[ "$FAIL" -eq 0 ] && echo "Tout est bon (0 echec)." || echo "$FAIL echec(s) -- voir ci-dessus."
echo "===================="

echo "== erreurs serveur (hors bcrypt) =="
grep -i "error\|exception" /tmp/uvicorn.log | grep -v bcrypt | grep -v "_bcrypt\|_load_backend" | grep -v "^Traceback" || echo "aucune"
