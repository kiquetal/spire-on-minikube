#!/bin/bash

echo "=== SPIRE CA Certificate Analysis ==="
echo ""

# Get all certificates from the bundle
BUNDLE=$(kubectl exec -n spire-server spire-server-0 -c spire-server -- \
  /opt/spire/bin/spire-server bundle show -format pem 2>/dev/null)

if [ -z "$BUNDLE" ]; then
  echo "Error: Could not fetch bundle from SPIRE server"
  exit 1
fi

echo "Analyzing certificates in bundle..."
echo ""

# Split bundle into individual certs and analyze each
echo "$BUNDLE" | awk '/BEGIN CERTIFICATE/,/END CERTIFICATE/' > /tmp/bundle.pem

CERT_NUM=0
cat /tmp/bundle.pem | awk '/BEGIN CERTIFICATE/,/END CERTIFICATE/ {print}' RS= | \
while read -r cert; do
  CERT_NUM=$((CERT_NUM + 1))
  
  NOT_BEFORE=$(echo "$cert" | openssl x509 -noout -startdate 2>/dev/null | cut -d= -f2)
  NOT_AFTER=$(echo "$cert" | openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2)
  
  if [ -n "$NOT_AFTER" ]; then
    EXPIRY_EPOCH=$(date -d "$NOT_AFTER" +%s 2>/dev/null)
    
    echo "Certificate #$CERT_NUM:"
    echo "  Valid from: $NOT_BEFORE"
    echo "  Expires at: $NOT_AFTER"
    echo "  Expiry epoch: $EXPIRY_EPOCH"
    echo ""
  fi
done

# Get newest certificate expiration
NEWEST_EXPIRY_DATE=$(cat /tmp/bundle.pem | \
  awk '/BEGIN CERTIFICATE/,/END CERTIFICATE/ {print}' RS= | \
  while read -r cert; do
    echo "$cert" | openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2
  done | \
  while read -r date; do
    echo "$(date -d "$date" +%s) $date"
  done | \
  sort -rn | head -1 | cut -d' ' -f2-)

NEWEST_EXPIRY_EPOCH=$(date -d "$NEWEST_EXPIRY_DATE" +%s 2>/dev/null)
NOW_EPOCH=$(date +%s)

echo "=== Summary ==="
echo "Current time: $(date)"
echo "Newest cert expires: $NEWEST_EXPIRY_DATE"
echo ""

SECONDS_UNTIL_EXPIRY=$((NEWEST_EXPIRY_EPOCH - NOW_EPOCH))
HOURS_UNTIL_EXPIRY=$((SECONDS_UNTIL_EXPIRY / 3600))
DAYS_UNTIL_EXPIRY=$((HOURS_UNTIL_EXPIRY / 24))

echo "Time until expiry:"
echo "  $SECONDS_UNTIL_EXPIRY seconds"
echo "  $HOURS_UNTIL_EXPIRY hours"
echo "  $DAYS_UNTIL_EXPIRY days"
echo ""

# Calculate optimal run time (1 hour before expiry)
OPTIMAL_RUN_EPOCH=$((NEWEST_EXPIRY_EPOCH - 3600))
OPTIMAL_RUN_DATE=$(date -d "@$OPTIMAL_RUN_EPOCH" "+%Y-%m-%d %H:%M:%S %Z")
OPTIMAL_HOUR=$(date -d "@$OPTIMAL_RUN_EPOCH" "+%H")
OPTIMAL_MINUTE=$(date -d "@$OPTIMAL_RUN_EPOCH" "+%M")

echo "=== Recommended CronJob Schedule ==="
echo "Optimal run time: $OPTIMAL_RUN_DATE"
echo "CronJob schedule: \"$OPTIMAL_MINUTE $OPTIMAL_HOUR * * *\""
echo ""
echo "This runs daily at $(date -d "@$OPTIMAL_RUN_EPOCH" "+%H:%M %Z"), 1 hour before cert expiry"
