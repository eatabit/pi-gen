#!/bin/bash

# AWS IoT Fleet Provisioning Script using mosquitto-clients
# This script provisions a device using the CreateKeysAndCertificate and RegisterThing APIs.
# Prerequisites:
# - mosquitto-clients and jq installed.
# - Pre-provision the device with a claim certificate (CLAIM_CERT), private key (CLAIM_KEY), and root CA (ROOT_CA).
# - Have a provisioning template named TEMPLATE_NAME in AWS IoT Core.
# - The claim certificate must allow actions like iot:CreateKeysAndCertificate, iot:RegisterThing.
#
# Usage: ./provision.sh <AWS_IOT_ENDPOINT> <SERIAL_NUMBER> <TEMPLATE_NAME> <CLAIM_CERT> <CLAIM_KEY> <ROOT_CA>
# Outputs: device_cert.pem, device_key.pem, thing_name.txt on success.

set -e  # Exit on error

# Log file setup
LOG_FILE="/var/log/iot-provisioning.log"

# Create log function with timestamp
log() {
    local message="$1"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] $message" | tee -a "$LOG_FILE"
}

# Ensure log file exists and is writable
touch "$LOG_FILE" 2>/dev/null || {
    LOG_FILE="./iot-provisioning.log"
    touch "$LOG_FILE"
}

ENDPOINT="a75p0fsmm0h6r-ats.iot.us-east-1.amazonaws.com"
SERIAL_NUMBER=$(cat /proc/cpuinfo | grep Serial | cut -d ' ' -f 2)
TEMPLATE_NAME="templateProvisioning"
CLAIM_CERT="/etc/aws-iot/71cc32e68839f91c3d1f96f5ad42e27bf3450c735b8eb928ebb9a0bfb9fb7235-certificate.pem.crt"
CLAIM_KEY="/etc/aws-iot/71cc32e68839f91c3d1f96f5ad42e27bf3450c735b8eb928ebb9a0bfb9fb7235-private.pem.key"
ROOT_CA="/etc/aws-iot/AmazonRootCA1.pem"

# Temporary files for responses
CREATE_RESPONSE=$(mktemp)
REGISTER_RESPONSE=$(mktemp)

# Function to send CreateKeysAndCertificate request and capture response
create_certificate() {
    log "Creating keys and certificate..."

    # Subscribe to responses in background, capture output to temp file
    mosquitto_sub -h "$ENDPOINT" -p 8883 --cafile "$ROOT_CA" --cert "$CLAIM_CERT" --key "$CLAIM_KEY" \
        -i "$SERIAL_NUMBER" \
        -t '$aws/certificates/create/json/accepted' \
        -t '$aws/certificates/create/json/rejected' > "$CREATE_RESPONSE" 2>/dev/null &
    SUB_PID=$!

    # Wait a bit for subscription
    sleep 2

    # Publish empty request
    mosquitto_pub -h "$ENDPOINT" -p 8883 --cafile "$ROOT_CA" --cert "$CLAIM_CERT" --key "$CLAIM_KEY" \
        -i "$SERIAL_NUMBER" \
        -t '$aws/certificates/create/json' -n > /dev/null 2>&1

    # Wait for response (up to 30 seconds)
    timeout=30
    while [ $timeout -gt 0 ]; do
        if grep -q '"certificateId"' "$CREATE_RESPONSE" 2>/dev/null; then
            kill $SUB_PID 2>/dev/null
            return 0
        fi
        if grep -q '"errorMessage"' "$CREATE_RESPONSE" 2>/dev/null; then
            kill $SUB_PID 2>/dev/null
            log "ERROR: Certificate creation rejected"
            cat "$CREATE_RESPONSE" | tee -a "$LOG_FILE"
            exit 1
        fi
        sleep 1
        timeout=$((timeout - 1))
    done

    kill $SUB_PID 2>/dev/null
    log "ERROR: Timeout waiting for certificate creation response"
    exit 1
}

# Function to send RegisterThing request and capture response
register_thing() {
    local token=$1
    log "Registering thing with token: ${token:0:20}..."

    # Subscribe to responses in background
    mosquitto_sub -h "$ENDPOINT" -p 8883 --cafile "$ROOT_CA" --cert "$CLAIM_CERT" --key "$CLAIM_KEY" \
        -i "$SERIAL_NUMBER" \
        -t "\$aws/provisioning-templates/$TEMPLATE_NAME/provision/json/accepted" \
        -t "\$aws/provisioning-templates/$TEMPLATE_NAME/provision/json/rejected" > "$REGISTER_RESPONSE" 2>/dev/null &
    SUB_PID=$!

    # Wait a bit for subscription
    sleep 2

    # Prepare payload
    PAYLOAD=$(jq -n --arg token "$token" '{"certificateOwnershipToken": $token}')

    # Publish request
    echo "$PAYLOAD" | mosquitto_pub -h "$ENDPOINT" -p 8883 --cafile "$ROOT_CA" --cert "$CLAIM_CERT" --key "$CLAIM_KEY" \
        -i "$SERIAL_NUMBER" \
        -t "\$aws/provisioning-templates/$TEMPLATE_NAME/provision/json" > /dev/null 2>&1

    # Wait for response (up to 30 seconds)
    timeout=30
    while [ $timeout -gt 0 ]; do
        if grep -q '"thingName"' "$REGISTER_RESPONSE" 2>/dev/null; then
            kill $SUB_PID 2>/dev/null
            return 0
        fi
        if grep -q '"errorMessage"' "$REGISTER_RESPONSE" 2>/dev/null; then
            kill $SUB_PID 2>/dev/null
            log "ERROR: Thing registration rejected"
            cat "$REGISTER_RESPONSE" | tee -a "$LOG_FILE"
            exit 1
        fi
        sleep 1
        timeout=$((timeout - 1))
    done

    kill $SUB_PID 2>/dev/null
    log "ERROR: Timeout waiting for thing registration response"
    exit 1
}

# Step 1: Create certificate
create_certificate

# Parse response
CERT_ID=$(jq -r '.certificateId' "$CREATE_RESPONSE")
CERT_PEM=$(jq -r '.certificatePem' "$CREATE_RESPONSE")
PRIVATE_KEY=$(jq -r '.privateKey' "$CREATE_RESPONSE")
TOKEN=$(jq -r '.certificateOwnershipToken' "$CREATE_RESPONSE")

log "Certificate created: $CERT_ID"

# Save device cert and key
echo "$CERT_PEM" > device_cert.pem
echo "$PRIVATE_KEY" > device_key.pem
log "Saved device certificate and private key"

# Step 2: Register thing
register_thing "$TOKEN"

# Parse response
THING_NAME=$(jq -r '.thingName' "$REGISTER_RESPONSE")
echo "$THING_NAME" > thing_name.txt

log "Provisioning complete!"
log "Thing Name: $THING_NAME"
log "Device Certificate: device_cert.pem"
log "Device Private Key: device_key.pem"
log "Endpoint: $ENDPOINT"

# Cleanup temps
rm -f "$CREATE_RESPONSE" "$REGISTER_RESPONSE"
log "Cleanup completed"