#!/usr/bin/env python3

import json
import os
import argparse
from awsiotsdk.mqtt_connection_builder import mtls_from_path
from awsiotsdk import iotshadow
from awscrt import io


# Get the Raspberry Pi serial number as unique client ID
def get_device_serial():
    try:
        with open("/proc/cpuinfo", "r") as f:
            for line in f:
                if line.startswith("Serial"):
                    return line.split(":")[1].strip()
    except:
        return "unknown-device"


# Paths to your provisioning claim (bootstrap) credentials
EATABIT_LIB_DIR = "/usr/local/lib/eatabit"
CLAIM_CERT = f"{EATABIT_LIB_DIR}/cert/71cc32e68839f91c3d1f96f5ad42e27bf3450c735b8eb928ebb9a0bfb9fb7235-certificate.pem.crt"
CLAIM_KEY = f"{EATABIT_LIB_DIR}/cert/71cc32e68839f91c3d1f96f5ad42e27bf3450c735b8eb928ebb9a0bfb9fb7235-private.pem.key"
ROOT_CA = f"{EATABIT_LIB_DIR}/cert/AmazonRootCA1.pem"
ENDPOINT = "a75p0fsmm0h6r-ats.iot.us-east-1.amazonaws.com"
CLIENT_ID = get_device_serial()
TEMPLATE_NAME = "templateProvisioning"

# Directories to save new certs/keys
CERT_DIR = f"{EATABIT_LIB_DIR}/cert"
os.makedirs(CERT_DIR, exist_ok=True)


def on_publish_create_keys_accepted(packet):
    print("CreateKeysAndCertificate accepted")
    payload = json.loads(packet.payload)
    cert = payload["certificatePem"]
    key = payload["keyPair"]["PrivateKey"]
    ownership_token = payload["certificateOwnershipToken"]

    cert_path = os.path.join(CERT_DIR, "device.pem.crt")
    key_path = os.path.join(CERT_DIR, "private.pem.key")

    with open(cert_path, "w") as f:
        f.write(cert)
    with open(key_path, "w") as f:
        f.write(key)

    print(f"Saved new certificate to {cert_path} and key to {key_path}")

    # Now register the thing
    register_payload = {
        "certificateOwnershipToken": ownership_token,
        "parameters": {"DeviceId": CLIENT_ID, "Version": "0.0.1"},
    }
    connection.publish(
        topic=f"$aws/provisioning-templates/{TEMPLATE_NAME}/provision/json",
        payload=json.dumps(register_payload),
        qos=1,
    )


def on_publish_register_thing_accepted(packet):
    print("RegisterThing accepted")
    payload = json.loads(packet.payload)
    print("Provisioning successful!")
    print("Thing Name:", payload.get("thingName"))
    # You can now disconnect and reconnect using the new cert/key for normal operations
    connection.disconnect()


def on_publish_rejected(packet, topic):
    print(f"{topic} rejected")
    payload = json.loads(packet.payload)
    print("Error:", payload)


if __name__ == "__main__":
    # Build MQTT connection using claim cert
    io.init_logging(getattr(io.LogLevel, "Info"), "stderr")
    connection = mtls_from_path(
        endpoint=ENDPOINT,
        cert_filepath=CLAIM_CERT,
        pri_key_filepath=CLAIM_KEY,
        ca_filepath=ROOT_CA,
        client_id=CLIENT_ID,
    )

    print("Connecting with provisioning claim certificate...")
    connect_future = connection.connect()
    connect_future.result()
    print("Connected!")

    # Subscribe to response topics
    create_keys_accepted, _ = connection.subscribe(
        topic="$aws/certificates/create/json/accepted",
        qos=1,
        callback=on_publish_create_keys_accepted,
    )

    create_keys_rejected, _ = connection.subscribe(
        topic="$aws/certificates/create/json/rejected",
        qos=1,
        callback=lambda packet: on_publish_rejected(packet, "CreateKeysAndCertificate"),
    )

    register_accepted, _ = connection.subscribe(
        topic=f"$aws/provisioning-templates/{TEMPLATE_NAME}/provision/json/accepted",
        qos=1,
        callback=on_publish_register_thing_accepted,
    )

    register_rejected, _ = connection.subscribe(
        topic=f"$aws/provisioning-templates/{TEMPLATE_NAME}/provision/json/rejected",
        qos=1,
        callback=lambda packet: on_publish_rejected(packet, "RegisterThing"),
    )

    # Publish to create keys and cert (empty payload for JSON)
    print("Publishing to CreateKeysAndCertificate...")
    connection.publish(topic="$aws/certificates/create/json", payload="{}", qos=1)

    # Keep the script running to receive responses
    print("Waiting for provisioning responses...")
    try:
        while True:
            pass
    except KeyboardInterrupt:
        print("Disconnecting...")
        connection.disconnect().result()
