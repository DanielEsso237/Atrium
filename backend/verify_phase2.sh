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

echo "== impression =="
CODE=$(curl -s -o /tmp/v_printer.json -w "%{http_code}" -X POST "$API/printers" -H "$AUTH" -H "Content-Type: application/json" \
  -d "{\"logical_name\":\"IMP_TEST_$TS\",\"label\":\"Imprimante test\",\"kind\":\"THERMAL\",\"protocol\":\"ESCPOS_NET\"}")
check "POST /printers" 201 "$CODE"
PRINTER_ID=$(python3 -c "import json;print(json.load(open('/tmp/v_printer.json')).get('id',''))")

CODE=$(curl -s -o /tmp/v_doctype.json -w "%{http_code}" -X POST "$API/document-types" -H "$AUTH" -H "Content-Type: application/json" \
  -d "{\"code\":\"TEST_TICKET_$TS\",\"label\":\"Ticket test\",\"default_kind\":\"THERMAL\"}")
check "POST /document-types" 201 "$CODE"
DOCTYPE_ID=$(python3 -c "import json;print(json.load(open('/tmp/v_doctype.json')).get('id',''))")

CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$API/print-routes" -H "$AUTH" -H "Content-Type: application/json" \
  -d "{\"document_type_id\":\"$DOCTYPE_ID\",\"printer_id\":\"$PRINTER_ID\",\"priority\":10}")
check "POST /print-routes" 201 "$CODE"

CODE=$(curl -s -o /tmp/v_tpl1.json -w "%{http_code}" -X POST "$API/document-templates" -H "$AUTH" -H "Content-Type: application/json" \
  -d "{\"document_type_id\":\"$DOCTYPE_ID\",\"format\":\"ESCPOS\",\"content\":\"v1\"}")
check "POST /document-templates (v1)" 201 "$CODE"
V1=$(python3 -c "import json;print(json.load(open('/tmp/v_tpl1.json'))['version'])")
CODE=$(curl -s -o /tmp/v_tpl2.json -w "%{http_code}" -X POST "$API/document-templates" -H "$AUTH" -H "Content-Type: application/json" \
  -d "{\"document_type_id\":\"$DOCTYPE_ID\",\"format\":\"ESCPOS\",\"content\":\"v2\"}")
V2=$(python3 -c "import json;print(json.load(open('/tmp/v_tpl2.json'))['version'])")
echo "  versions successives : $V1 puis $V2 (doit etre 1 puis 2)"
[ "$V1" = "1" ] && [ "$V2" = "2" ] && echo "  OK   versionnage des modeles" || { echo "  FAIL versionnage des modeles"; FAIL=$((FAIL+1)); }

echo "== reservations : disponibilite =="
STD_ID=$(curl -s "$API/room-types" -H "$AUTH" | python3 -c "import sys,json; print([t['id'] for t in json.load(sys.stdin) if t['code']=='STD'][0])")
curl -s "$API/reservations/availability?room_type_id=$STD_ID&arrival_date=2027-01-10&departure_date=2027-01-12" -H "$AUTH"
echo

echo "== reservations : creation =="
GUEST_ID=$(curl -s -X POST "$API/guests" -H "$AUTH" -H "Content-Type: application/json" \
  -d "{\"first_name\":\"Koffi\",\"last_name\":\"Test$TS\"}" | python3 -c "import sys,json;print(json.load(sys.stdin)['id'])")

CODE=$(curl -s -o /tmp/v_res.json -w "%{http_code}" -X POST "$API/reservations" -H "$AUTH" -H "Content-Type: application/json" \
  -d "{\"guest_id\":\"$GUEST_ID\",\"rooms\":[{\"room_type_id\":\"$STD_ID\",\"arrival_date\":\"2027-01-10\",\"departure_date\":\"2027-01-12\"}]}")
check "POST /reservations" 201 "$CODE"
cat /tmp/v_res.json
echo
RES_ID=$(python3 -c "import json;print(json.load(open('/tmp/v_res.json'))['id'])")
LINE_ID=$(python3 -c "import json;print(json.load(open('/tmp/v_res.json'))['rooms'][0]['id'])")
TOTAL=$(python3 -c "import json;print(json.load(open('/tmp/v_res.json'))['estimated_total'])")
echo "  estimated_total=$TOTAL (attendu 50000 = 2 nuits x 25000 STD)"
[ "$TOTAL" = "50000" ] && echo "  OK   calcul du montant" || { echo "  FAIL calcul du montant"; FAIL=$((FAIL+1)); }

echo "== reservations : surbooking refuse =="
CODE=0
for i in $(seq 1 10); do
  CODE=$(curl -s -o /tmp/v_over.json -w "%{http_code}" -X POST "$API/reservations" -H "$AUTH" -H "Content-Type: application/json" \
    -d "{\"guest_id\":\"$GUEST_ID\",\"rooms\":[{\"room_type_id\":\"$STD_ID\",\"arrival_date\":\"2027-02-01\",\"departure_date\":\"2027-02-02\"}]}")
  [ "$CODE" = "409" ] && break
done
check "POST /reservations en surbooking (409 attendu apres N essais)" 409 "$CODE"

echo "== check-in =="
ROOM_ID=$(curl -s "$API/rooms" -H "$AUTH" | python3 -c "
import sys, json
rooms = json.load(sys.stdin)
r = [x for x in rooms if x['room_type']['code']=='STD' and x['occupancy_status']=='VACANT'][0]
print(r['id'])
")
CODE=$(curl -s -o /tmp/v_checkin.json -w "%{http_code}" -X POST "$API/reservations/$RES_ID/rooms/$LINE_ID/check-in" \
  -H "$AUTH" -H "Content-Type: application/json" -d "{\"room_id\":\"$ROOM_ID\"}")
check "POST check-in" 200 "$CODE"
LINE_STATUS=$(python3 -c "import json;print(json.load(open('/tmp/v_checkin.json'))['rooms'][0]['status'])")
echo "  statut ligne apres check-in: $LINE_STATUS"

ROOM_STATUS=$(curl -s "$API/rooms" -H "$AUTH" | python3 -c "
import sys, json
rooms = json.load(sys.stdin)
r = [x for x in rooms if x['id']=='$ROOM_ID'][0]
print(r['occupancy_status'])
")
echo "  occupancy_status de la chambre apres check-in: $ROOM_STATUS (attendu OCCUPIED)"
[ "$ROOM_STATUS" = "OCCUPIED" ] && echo "  OK   effet reel sur la chambre" || { echo "  FAIL effet reel sur la chambre"; FAIL=$((FAIL+1)); }

echo "== check-in en double refuse (409) =="
CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$API/reservations/$RES_ID/rooms/$LINE_ID/check-in" \
  -H "$AUTH" -H "Content-Type: application/json" -d "{}")
check "double check-in" 409 "$CODE"

echo "== annulation refusee apres arrivee (409) =="
CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$API/reservations/$RES_ID/cancel" -H "$AUTH" -H "Content-Type: application/json" -d '{}')
check "annulation apres check-in" 409 "$CODE"

echo "== check-out =="
CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$API/reservations/$RES_ID/rooms/$LINE_ID/check-out" -H "$AUTH")
check "POST check-out" 200 "$CODE"

ROOM_STATUS2=$(curl -s "$API/rooms" -H "$AUTH" | python3 -c "
import sys, json
rooms = json.load(sys.stdin)
r = [x for x in rooms if x['id']=='$ROOM_ID'][0]
print(r['occupancy_status'], r['housekeeping_status'])
")
echo "  chambre apres check-out: $ROOM_STATUS2 (attendu VACANT DIRTY)"
[ "$ROOM_STATUS2" = "VACANT DIRTY" ] && echo "  OK   chambre liberee et marquee sale" || { echo "  FAIL etat chambre apres check-out"; FAIL=$((FAIL+1)); }

echo
echo "===================="
[ "$FAIL" -eq 0 ] && echo "Tout est bon (0 echec)." || echo "$FAIL echec(s) -- voir ci-dessus."
echo "===================="

echo "== erreurs serveur (hors bcrypt) =="
grep -i "error\|exception" /tmp/uvicorn.log | grep -v bcrypt | grep -v "_bcrypt\|_load_backend" | grep -v "^Traceback" || echo "aucune"
