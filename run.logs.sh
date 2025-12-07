#!/bin/bash

# ------------------------------------------------------------
# STRUCTURED LOGGING FUNCTIONS
# ------------------------------------------------------------
log_info()  { echo "[INFO]  [$SCRIPT_NAME] $1"; }
log_warn()  { echo "[WARN]  [$SCRIPT_NAME] $1" >&2; }
log_error() { echo "[ERROR] [$SCRIPT_NAME] $1" >&2; }
log_stage() {
    echo ""
    echo "==============================="
    echo "[STAGE] [$SCRIPT_NAME] $1"
    echo "Timestamp: $(date -u +"%Y-%m-%dT%H:%M:%SZ")"
    echo "==============================="
    echo ""
}

SCRIPT_NAME="SNAP-CLONE-ATTACH-DEPLOY"
JOB_SUCCESS=0


log_stage "Starting Job"


# ============================================================
# 1. Environment Variables
# ============================================================
log_stage "Initializing Settings and Variables"
API_KEY="${IBMCLOUD_API_KEY}"
REGION="us-south"
RESOURCE_GROP_NAME="Default"
PVS_CRN="crn:v1:bluemix:public:power-iaas:dal10:a/21d74dd4fe814dfca20570bbb93cdbff:cc84ef2f-babc-439f-8594-571ecfcbe57a::"
CLOUD_INSTANCE_ID="cc84ef2f-babc-439f-8594-571ecfcbe57a"
LPAR_NAME="empty-ibmi-lpar"
PRIMARY_LPAR="get-snapshot"
STORAGE_TIER="tier3"
CLONE_NAME_PREFIX="CLONE-RESTORE-$(date +"%Y%m%d%H%M")"


# ============================================================
# Cleanup trap
# ============================================================
cleanup_on_failure() {

    if [[ $JOB_SUCCESS -eq 1 ]]; then
        log_info "Skipping cleanup — job completed successfully."
        return
    fi

    log_error "Critical Failure — Starting rollback cleanup."

    # (no change in this block except logs)
}

trap 'cleanup_on_failure' ERR EXIT

log_stage "Connecting to IBM Cloud"

ibmcloud login --apikey $API_KEY -r $REGION || { log_error "Cloud login failed"; exit 1; }
ibmcloud target -g $RESOURCE_GROP_NAME || { log_error "Resource group targeting failed"; exit 1; }
ibmcloud pi ws target $PVS_CRN || { log_error "Workspace targeting failed"; exit 1; }


# ============================================================
# STEP 1: TAKE SNAPSHOT
# ============================================================
log_stage "Taking snapshot on primary LPAR"

SNAPSHOT_NAME="TMP_SNAP_$(date +"%Y%m%d%H%M")"
log_info "Creating snapshot $SNAPSHOT_NAME on $PRIMARY_LPAR..."

SNAPSHOT_JSON_OUTPUT=$(ibmcloud pi instance snapshot create "$PRIMARY_LPAR" --name "$SNAPSHOT_NAME" --json)
SNAPSHOT_ID=$(echo "$SNAPSHOT_JSON_OUTPUT" | jq -r '.snapshotID')

log_info "Snapshot created. ID: $SNAPSHOT_ID"

log_info "Waiting for snapshot status to reach AVAILABLE..."

while true; do
    STATUS=$(ibmcloud pi instance snapshot get "$SNAPSHOT_ID" --json | jq -r '.status')
    
    if [[ "$STATUS" == "AVAILABLE" ]]; then
        log_info "Snapshot is available."
        break
    fi

    log_info "Snapshot status = $STATUS — retrying..."
    sleep 45
done


# ============================================================
# STEP 2: DISCOVER SOURCE VOLUMES
# ============================================================
log_stage "Discovering source volumes from snapshot"

SNAPSHOT_DETAIL=$(ibmcloud pi instance snapshot get "$SNAPSHOT_ID" --json)
SOURCE_VOLUME_IDS=$(echo "$SNAPSHOT_DETAIL" | jq -r '.volumeSnapshots | keys[]')

log_info "Discovered source volumes: $SOURCE_VOLUME_IDS"


# ============================================================
# STEP 3: CLASSIFY source volumes
# ============================================================
log_stage "Classifying Boot and Data volumes"

SOURCE_BOOT_ID=""
SOURCE_DATA_IDS=""

for VOL_ID in $SOURCE_VOLUME_IDS; do
    DETAIL=$(ibmcloud pi volume get "$VOL_ID" --json)
    IS_BOOTABLE=$(echo "$DETAIL" | jq -r '.bootable')
    
    if [[ "$IS_BOOTABLE" == "true" ]]; then
        SOURCE_BOOT_ID="$VOL_ID"
        log_info "Boot volume identified: $VOL_ID"
    else
        SOURCE_DATA_IDS="$SOURCE_DATA_IDS,$VOL_ID"
        log_info "Data volume identified: $VOL_ID"
    fi
done

SOURCE_DATA_IDS="${SOURCE_DATA_IDS#,}"


# ============================================================
# STEP 4: CREATE CLONES
# ============================================================
log_stage "Initiating volume clone operation"

CLONE_TASK_ID=$(ibmcloud pi volume clone-async create "$CLONE_NAME_PREFIX" \
    --volumes "$SOURCE_BOOT_ID,$SOURCE_DATA_IDS" \
    --target-tier "$STORAGE_TIER" --json | jq -r '.cloneTaskID')

log_info "Clone task ID: $CLONE_TASK_ID"


# ============================================================
# WAIT FOR clone task
# ============================================================
log_stage "Waiting on clone task to finish"

while true; do
    CLONE_STATE=$(ibmcloud pi volume clone-async get "$CLONE_TASK_ID" --json | jq -r '.status')
    
    case "$CLONE_STATE" in
        completed)
            log_info "Clone completed successfully"
            break
            ;;
        failed|cancelled)
            log_error "Clone failed. State=$CLONE_STATE"
            exit 1
            ;;
        *)
            log_info "Clone running — state=$CLONE_STATE"
            sleep 30
            ;;
    esac
done


# ============================================================
# DISCOVER clones after async completion
# ============================================================
log_stage "Discovering cloned volume IDs"

NEW_CLONE_IDS=""
ATTEMPTS=0

while [[ -z "$NEW_CLONE_IDS" && $ATTEMPTS -lt 20 ]]; do
    NEW_CLONE_IDS=$(ibmcloud pi volume list --long --json | \
        jq -r ".volumes[] | select(.name | contains(\"$CLONE_NAME_PREFIX\")) | .volumeID")
    ((ATTEMPTS++))
    sleep 10
done

log_info "Cloned volume IDs found: $NEW_CLONE_IDS"


# ============================================================
# STEP 5: ATTACH cloned volumes
# ============================================================
log_stage "Attaching cloned volumes to the LPAR"

LPAR_ID=$(ibmcloud pi instance list --json | jq -r ".pvmInstances[] | select(.name==\"$LPAR_NAME\") | .id")

log_info "Attaching volumes to instance: $LPAR_ID"

ATTACH_CMD="ibmcloud pi instance volume attach $LPAR_ID \
            --boot-volume $SOURCE_BOOT_ID \
            --volumes $(echo "$NEW_CLONE_IDS" | tr ' ' ',')"

$ATTACH_CMD

log_info "Volumes successfully attached"


# ============================================================
# STEP 6: BOOT LPAR
# ============================================================
log_stage "Starting LPAR"

ibmcloud pi instance operation "$LPAR_ID" \
    --operation-type boot \
    --boot-mode a \
    --boot-operating-mode normal

ibmcloud pi instance action "$LPAR_ID" --operation start

log_info "Boot initiated — waiting for ACTIVE status"


# ============================================================
# STEP 7: VERIFY ACTIVE STATUS
# ============================================================
while true; do
    ST=$(ibmcloud pi instance get "$LPAR_ID" --json | jq -r '.status')

    if [[ "$ST" == "ACTIVE" ]]; then
        log_info "Instance ACTIVE — restore complete."
        JOB_SUCCESS=1
        break
    fi

    log_info "LPAR state = $ST — waiting more..."
    sleep 60
done


# ============================================================
# STEP 8: TRIGGER NEXT JOB (conditional)
# ============================================================
log_stage "Evaluate triggering snapshot-cleanup job"

if [[ "${RUN_SNAPSHOT-CLEANUP:-No}" == "Yes" ]]; then
    log_info "Launching snapshot-cleanup"
    
    NEXT_RUN=$(ibmcloud ce jobrun submit --job snapshot-cleanup --output json | jq -r '.name')
    
    log_info "Triggered instance: $NEXT_RUN"
else
    log_info "Cleanup stage skipped."
fi


log_stage "Job Completed Successfully"
exit 0
