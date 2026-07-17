#!/bin/bash
set -euo pipefail

GALLERY_RG="${GALLERY_RESOURCE_GROUP}"
GALLERY_NAME="${GALLERY_NAME}"
IMAGE_DEF="${IMAGE_DEFINITION}"
IMAGE_VER="${IMAGE_VERSION}"
DEST_STORAGE="${DEST_STORAGE_ACCOUNT}"
DEST_RG="${DEST_RESOURCE_GROUP}"
CONTAINER="${OUTPUT_CONTAINER}"
SAS_HOURS="${SAS_HOURS:-1}"

echo "=== Citrix Flex Image Export ==="
echo "Gallery  : ${GALLERY_NAME} / ${IMAGE_DEF} @ ${IMAGE_VER}"
echo "Dest     : ${DEST_STORAGE}/${CONTAINER}"

# ── Download AzCopy for Linux ──────────────────────────────────────────────────
echo ""
echo "Downloading AzCopy v10..."
curl -sL https://aka.ms/downloadazcopy-v10-linux -o /tmp/azcopy.tar.gz
tar -xzf /tmp/azcopy.tar.gz -C /tmp
AZCOPY=$(find /tmp -name "azcopy" -type f | head -1)
chmod +x "$AZCOPY"
export AZCOPY_AUTO_LOGIN_TYPE=MSI    # Destination auth via managed identity
echo "  AzCopy ready."

# ── Detect gallery location and security type ──────────────────────────────────
echo ""
echo "Verifying gallery image version..."
SUBSCRIPTION_ID=$(az account show --query id -o tsv)

VERSION_STATE=$(az sig image-version show \
    --resource-group "$GALLERY_RG" \
    --gallery-name "$GALLERY_NAME" \
    --gallery-image-definition "$IMAGE_DEF" \
    --gallery-image-version "$IMAGE_VER" \
    --query "provisioningState" -o tsv)

if [ "$VERSION_STATE" != "Succeeded" ]; then
    echo "ERROR: Image version is not in Succeeded state: ${VERSION_STATE}" >&2
    exit 1
fi

GALLERY_LOCATION=$(az sig show \
    --resource-group "$GALLERY_RG" \
    --gallery-name "$GALLERY_NAME" \
    --query "location" -o tsv)

SECURITY_TYPE=$(az sig image-definition show \
    --resource-group "$GALLERY_RG" \
    --gallery-name "$GALLERY_NAME" \
    --gallery-image-definition "$IMAGE_DEF" \
    --query "features[?name=='SecurityType'].value | [0]" -o tsv 2>/dev/null || echo "")

IS_TRUSTED_LAUNCH=false
if [ "$SECURITY_TYPE" = "TrustedLaunch" ]; then
    IS_TRUSTED_LAUNCH=true
fi

echo "  Provisioning state : ${VERSION_STATE}"
echo "  Gallery location   : ${GALLERY_LOCATION}"
echo "  Security type      : ${SECURITY_TYPE:-Standard Gen2}"

# ── Create temporary managed disk ─────────────────────────────────────────────
GALLERY_VERSION_ID="/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${GALLERY_RG}/providers/Microsoft.Compute/galleries/${GALLERY_NAME}/images/${IMAGE_DEF}/versions/${IMAGE_VER}"
DISK_NAME="export-temp-$(echo "${IMAGE_DEF}" | tr '[:upper:]' '[:lower:]')-$(echo "${IMAGE_VER}" | tr '.' '-')"
DISK_NAME="${DISK_NAME:0:80}"

echo ""
echo "Creating temporary managed disk..."
echo "  Disk name: ${DISK_NAME}  (deleted after copy)"

if [ "$IS_TRUSTED_LAUNCH" = true ]; then
    echo "  Passing --security-type TrustedLaunch (required for TrustedLaunch gallery images)"
    az disk create \
        --resource-group "$GALLERY_RG" \
        --name "$DISK_NAME" \
        --gallery-image-reference "$GALLERY_VERSION_ID" \
        --location "$GALLERY_LOCATION" \
        --sku Standard_LRS \
        --security-type TrustedLaunch \
        --output none
else
    az disk create \
        --resource-group "$GALLERY_RG" \
        --name "$DISK_NAME" \
        --gallery-image-reference "$GALLERY_VERSION_ID" \
        --location "$GALLERY_LOCATION" \
        --sku Standard_LRS \
        --output none
fi
echo "  Disk created."

# Ensure the disk is deleted even if the script fails
cleanup() {
    echo ""
    echo "Cleaning up temporary disk..."
    az disk revoke-access --resource-group "$GALLERY_RG" --name "$DISK_NAME" --output none 2>/dev/null || true
    az disk delete --resource-group "$GALLERY_RG" --name "$DISK_NAME" --yes --output none 2>/dev/null || true
    echo "  Temporary disk deleted."
}
trap cleanup EXIT

# ── Grant disk access (OS SAS + VMGS SAS for TrustedLaunch) ───────────────────
echo ""
echo "Granting disk access..."
SAS_JSON=$(az disk grant-access \
    --resource-group "$GALLERY_RG" \
    --name "$DISK_NAME" \
    --duration-in-seconds 86400 \
    --access-level Read \
    --secure-vm-guest-state-sas \
    -o json)

SOURCE_SAS=$(echo "$SAS_JSON" | jq -r '.accessSAS // ""')
VMGS_SAS=$(echo "$SAS_JSON"  | jq -r '.securityDataAccessSAS // ""')

if [ -z "$SOURCE_SAS" ]; then
    echo "ERROR: OS disk SAS not returned by az disk grant-access" >&2
    exit 1
fi
echo "  OS SAS obtained."
if [ -n "$VMGS_SAS" ]; then
    echo "  VMGS SAS obtained — TrustedLaunch confirmed."
else
    echo "  VMGS SAS not returned — image does not have VM guest state."
    echo "  Proceeding with OS disk only. Set secure_boot_enabled = false in Citrix portal."
fi

# ── AzCopy to destination blob storage ────────────────────────────────────────
# Destination auth uses MSI (AZCOPY_AUTO_LOGIN_TYPE=MSI set above)
SAFE_NAME="${IMAGE_DEF}-$(echo "${IMAGE_VER}" | tr '.' '-')"
OS_BLOB="${SAFE_NAME}.vhd"
OS_DEST="https://${DEST_STORAGE}.blob.core.windows.net/${CONTAINER}/${OS_BLOB}"

echo ""
echo "Copying OS disk VHD to blob storage..."
"$AZCOPY" copy "$SOURCE_SAS" "$OS_DEST" --blob-type PageBlob

VMGS_BLOB=""
if [ -n "$VMGS_SAS" ]; then
    VMGS_BLOB="${SAFE_NAME}-vmgs.vhd"
    VMGS_DEST="https://${DEST_STORAGE}.blob.core.windows.net/${CONTAINER}/${VMGS_BLOB}"
    echo ""
    echo "Copying VMGS blob..."
    "$AZCOPY" copy "$VMGS_SAS" "$VMGS_DEST" --blob-type PageBlob
fi

# cleanup trap runs here (revokes access + deletes disk)

# ── Generate read SAS tokens (user delegation — no account key needed) ─────────
echo ""
echo "Generating read SAS tokens (${SAS_HOURS}-hour expiry)..."

# User delegation SAS requires Storage Blob Delegator role on the storage account
EXPIRY=$(date -u -d "+${SAS_HOURS} hours" '+%Y-%m-%dT%H:%MZ')

az account set --subscription "$SUBSCRIPTION_ID" 2>/dev/null

VHD_SAS_TOKEN=$(az storage blob generate-sas \
    --account-name "$DEST_STORAGE" \
    --container-name "$CONTAINER" \
    --name "$OS_BLOB" \
    --permissions r \
    --expiry "$EXPIRY" \
    --auth-mode login \
    --as-user \
    --https-only \
    -o tsv)
VHD_URI="https://${DEST_STORAGE}.blob.core.windows.net/${CONTAINER}/${OS_BLOB}?${VHD_SAS_TOKEN}"

GUEST_DISK_URI=""
SECURE_BOOT="false"
VTPM="false"
if [ -n "$VMGS_BLOB" ]; then
    VMGS_SAS_TOKEN=$(az storage blob generate-sas \
        --account-name "$DEST_STORAGE" \
        --container-name "$CONTAINER" \
        --name "$VMGS_BLOB" \
        --permissions r \
        --expiry "$EXPIRY" \
        --auth-mode login \
        --as-user \
        --https-only \
        -o tsv)
    GUEST_DISK_URI="https://${DEST_STORAGE}.blob.core.windows.net/${CONTAINER}/${VMGS_BLOB}?${VMGS_SAS_TOKEN}"
    SECURE_BOOT="true"
    VTPM="true"
fi

echo ""
echo "=== Export complete ==="
echo "vhd_uri        : ${VHD_URI}"
[ -n "$GUEST_DISK_URI" ] && echo "guest_disk_uri : ${GUEST_DISK_URI}"
echo "SAS expires    : ${EXPIRY} UTC"

# ── Write deployment outputs ───────────────────────────────────────────────────
OUTPUT_FILE="$AZ_SCRIPTS_OUTPUT_PATH"
jq -n \
    --arg vhdUri        "$VHD_URI" \
    --arg guestDiskUri  "$GUEST_DISK_URI" \
    --arg secureBoot    "$SECURE_BOOT" \
    --arg vtpm          "$VTPM" \
    --arg sasExpiry     "${EXPIRY} UTC" \
    '{
        vhdUri:           $vhdUri,
        guestDiskUri:     $guestDiskUri,
        secureBootEnabled: $secureBoot,
        vTPMEnabled:      $vtpm,
        sasExpiry:        $sasExpiry
    }' > "$OUTPUT_FILE"

echo "Outputs written."
