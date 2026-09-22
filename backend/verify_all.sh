#!/bin/bash
set -e
cd "$(dirname "$0")"

echo "################################################"
echo "# 1/5 -- fondations (auth, clients, chambres, personnel)"
echo "################################################"
bash verify.sh

echo
echo "################################################"
echo "# 2/5 -- reservations + check-in/out"
echo "################################################"
bash verify_phase2.sh

echo
echo "################################################"
echo "# 3/5 -- facturation"
echo "################################################"
bash verify_phase2_billing.sh

echo
echo "################################################"
echo "# 4/5 -- commandes restaurant"
echo "################################################"
bash verify_orders.sh

echo
echo "################################################"
echo "# 5/5 -- housekeeping, maintenance, stock"
echo "################################################"
bash verify_ops.sh

echo
echo "################################################"
echo "# 6/6 -- dashboard (vues statistiques)"
echo "################################################"
bash verify_dashboard.sh
echo
echo "################################################"
echo "# TOUT EST VERIFIE."
echo "################################################"
