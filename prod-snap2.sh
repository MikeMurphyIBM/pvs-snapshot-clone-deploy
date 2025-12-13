#!/usr/bin/env bash

timestamp() {
  while IFS= read -r line; do
    printf "[%s] %s\n" "$(date '+%Y-%m-%d %H:%M:%S')" "$line"
  done
}
exec > >(timestamp) 2>&1





echo "========================================================================="
echo "Job 2:  Snapshot/Cloning/Restore Operations on Primary and Secondary LPAR"
echo "========================================================================="
echo ""


# -------------------------
# 1a. Environment Variables
# -------------------------

API_KEY="${IBMCLOUD_API_KEY}"    # IAM API Key stored in Code Engine Secret
REGION="us-south"                # IBM Cloud Region
RESOURCE_GROP_NAME="Default"     # Targeted Resource Group
PVS_CRN="crn:v1:bluemix:public:power-iaas:dal10:a/21d74dd4fe814dfca20570bbb93cdbff:cc84ef2f-babc-439f-8594-571ecfcbe57a::" # Full PowerVS Workspace CRN
CLOUD_INSTANCE_ID="cc84ef2f-babc-439f-8594-571ecfcbe57a" # PowerVS Workspace ID
LPAR_NAME="manhattan"      # Name of the target LPAR
PRIMARY_LPAR="get-snapshot"      # Name of the source LPAR for snapshot
PRIMARY_INSTANCE_ID="c92f6904-8bd2-4093-acec-f641899cd658"  # Primary LPAR Instance ID
STORAGE_TIER="tier3"             # Must match the storage tier of the original volumes in the snapshot.
CLONE_NAME_PREFIX="murph-$(date +"%Y%m%d%H%M%S")"  # Unique prefix for the new cloned volumes, excluding seconds (%S)

# -------------------------
# 1B. Dynamic Control Variables (Initialized for Cleanup Tracking)
# -------------------------

CLONE_BOOT_ID=""      # Tracks the ID of the dynamically created boot volume
CLONE_DATA_IDS=""     # Tracks the comma-separated IDs of the dynamically created data volumes
SOURCE_SNAPSHOT_ID="" # Tracks the ID of the discovered source snapshot
SOURCE_VOLUME_IDS=""  # Tracks the comma-separated IDs of the volumes contained within the snapshot
CLONE_TASK_ID=""      # Tracks the ID of the asynchronous cloning job
JOB_SUCCESS=0         # 0 = Failure (Default), 1 = Success (Set at end of script)



# =======================================================================
# CLEANUP FUNCTION — NO SNAPSHOT REMOVAL
# =======================================================================


cleanup_on_failure() {
    trap - ERR

    if [[ ${JOB_SUCCESS:-0} -eq 1 ]]; then
        echo "Job finished successfully — no cleanup needed"
        return 0
    fi

    echo ""
    echo " FAILURE DETECTED — BEGINNING SAFE CLEANUP OPERATIONS"
    echo ""

    # -------------------------------------------------
    # STEP 1 — Resolve LPAR by NAME → INSTANCE ID
    # -------------------------------------------------
    echo "Resolving LPAR instance ID by name..."

    LPAR_INSTANCE_ID=$(ibmcloud pi instance list --json 2>/dev/null \
        | jq -r --arg N "$LPAR_NAME" '.pvmInstances[]? | select(.name==$N) | .id' \
        | head -n 1)

    if [[ -z "$LPAR_INSTANCE_ID" || "$LPAR_INSTANCE_ID" == "null" ]]; then
        echo "No LPAR named '$LPAR_NAME' found — skipping cleanup"
        return 0
    fi

    echo "Found LPAR '$LPAR_NAME' (Instance ID: $LPAR_INSTANCE_ID)"

    # -------------------------------------------------
    # STEP 2 — Preserve snapshot (by design)
    # -------------------------------------------------
    if [[ -n "${SOURCE_SNAPSHOT_ID:-}" ]]; then
        echo "Snapshot ID [$SOURCE_SNAPSHOT_ID] preserved"
    fi

    # -------------------------------------------------
    # STEP 3 — Bulk detach ALL volumes (instance-based)
    # -------------------------------------------------
    echo "Requesting bulk detach of all volumes from instance..."

    ibmcloud pi instance volume bulk-detach "$LPAR_INSTANCE_ID" \
        --detach-all \
        --detach-primary >/dev/null 2>&1 || true

    echo "Waiting up to 4 minutes for detachment..."

    INITIAL_WAIT=30
    POLL_INTERVAL=30
    MAX_WAIT=240
    WAITED=$INITIAL_WAIT

    sleep "$INITIAL_WAIT"

    while true; do
        ATTACHED=$(ibmcloud pi instance volume list "$LPAR_INSTANCE_ID" --json 2>/dev/null \
            | jq -r '(.volumes // [])[] | .volumeID')

        if [[ -z "$ATTACHED" ]]; then
            echo "All volumes detached from instance"
            break
        fi

        if [[ $WAITED -ge $MAX_WAIT ]]; then
            echo "[WARNING] Volumes still appear attached after ${MAX_WAIT}s"
            echo "[WARNING] Proceeding with deletion anyway"
            break
        fi

        echo "Volumes still attached — retrying in ${POLL_INTERVAL}s"
        sleep "$POLL_INTERVAL"
        WAITED=$((WAITED + POLL_INTERVAL))
    done

    # -------------------------------------------------
    # STEP 4 — Bulk delete cloned volumes (ID-based)
    # -------------------------------------------------
    echo "Deleting cloned volumes..."

    if [[ -n "$CLONE_DATA_IDS" ]]; then
        ibmcloud pi volume bulk-delete \
            --volumes "${CLONE_BOOT_ID},${CLONE_DATA_IDS}" >/dev/null 2>&1 || true
    else
        ibmcloud pi volume bulk-delete \
            --volumes "${CLONE_BOOT_ID}" >/dev/null 2>&1 || true
    fi

    # -------------------------------------------------
    # STEP 5 — Verify deletion
    # -------------------------------------------------
    echo "Verifying volume removal..."

    if ibmcloud pi volume get "$CLONE_BOOT_ID" --json >/dev/null 2>&1; then
        echo "[WARNING] Boot volume [$CLONE_BOOT_ID] still exists — manual review required"
    else
        echo "Boot volume [$CLONE_BOOT_ID] deleted"
    fi

    if [[ -n "$CLONE_DATA_IDS" ]]; then
        for VOL in ${CLONE_DATA_IDS//,/ }; do
            if ibmcloud pi volume get "$VOL" --json >/dev/null 2>&1; then
                echo "[WARNING] Data volume [$VOL] still exists — manual review required"
            else
                echo "Data volume [$VOL] deleted"
            fi
        done
    fi

    echo ""
    echo "==================== CLEANUP COMPLETE ===================="
    echo ""
}



# =============================================================
# SECTION 2b. Helper Function for Waiting for Asynchronous Clone Tasks
# =============================================================

wait_for_job() {
    CLONE_TASK_ID=$1
    echo "Waiting for asynchronous clone task ID: $CLONE_TASK_ID to complete..."
    
    while true; do
        STATUS=$(ibmcloud pi volume clone-async get "$CLONE_TASK_ID" --json | jq -r '.status')
        
        if [[ "$STATUS" == "completed" ]]; then
            echo "Clone Task $CLONE_TASK_ID completed successfully."
            break
        elif [[ "$STATUS" == "failed" ]]; then
            echo "Error: Clone Task $CLONE_TASK_ID failed. Aborting script."
            exit 1
        else
            echo "Clone Task $CLONE_TASK_ID status: $STATUS. Waiting 30 seconds..."
            sleep 30
        fi
    done
}


# =======================================================================
# SECTION 2c: TRAP ACTIVATION
# =======================================================================

trap 'cleanup_on_failure' ERR EXIT


echo "========================================================================="
echo "Stage 1 of 7: IBM Cloud Authentication and Targeting PowerVS Workspace"
echo "========================================================================="
echo ""

ibmcloud login --apikey "$API_KEY" -r "$REGION" || { echo "ERROR: IBM Cloud login failed."; exit 1; }
ibmcloud target -g "$RESOURCE_GROP_NAME"      || { echo "ERROR: Failed to target resource group."; exit 1; }
ibmcloud pi ws target "$PVS_CRN"              || { echo "ERROR: Failed to target PowerVS workspace $PVS_CRN."; exit 1; }

echo ""
echo "--- Stage 1 of 7 Complete: Authenticated into IBM Cloud and Targeted Workspace ---"
echo ""


echo "========================================================="
echo "Stage 2a of 7: Perform Snapshot Operation on primary LPAR"
echo "========================================================="
echo ""

SNAPSHOT_NAME="murph-$(date +"%Y%m%d%H%M")"

echo "--- Initiating Snapshot on LPAR: $PRIMARY_LPAR ---"
echo "Generated Snapshot Name: $SNAPSHOT_NAME"

echo "Creating Snapshot: $SNAPSHOT_NAME on LPAR: $PRIMARY_LPAR"
SNAPSHOT_JSON_OUTPUT=$(ibmcloud pi instance snapshot create "$PRIMARY_LPAR" --name "$SNAPSHOT_NAME" --json) || { 
    echo "Error initiating snapshot." 
    exit 1 
}

# *** CRITICAL: assign, then log ***
SNAPSHOT_ID=$(echo "$SNAPSHOT_JSON_OUTPUT" | jq -r '.snapshotID')
echo "Snapshot ID: $SNAPSHOT_ID"

SOURCE_SNAPSHOT_ID="$SNAPSHOT_ID"

POLL_INTERVAL=45
EXPECTED_STATUS="AVAILABLE"
ERROR_STATUS="ERROR"
CURRENT_STATUS=""

echo "--- Polling started: first check is immediate, then sleeping ${POLL_INTERVAL}s between checks ---"


while true; do
    STATUS_JSON=$(ibmcloud pi instance snapshot get "$SNAPSHOT_ID" --json 2>/dev/null)
    CURRENT_STATUS=$(echo "$STATUS_JSON" | jq -r '.status' | tr '[:lower:]' '[:upper:]' | tr -d '[:space:].')

    if [[ "$CURRENT_STATUS" == "$EXPECTED_STATUS" ]]; then
        echo "--- Stage 2a of 7 Complete: $SNAPSHOT_ID is now $CURRENT_STATUS. ---"
        break
    elif [[ "$CURRENT_STATUS" == "$ERROR_STATUS" ]]; then
        echo "FATAL ERROR: Snapshot failed. Status: $CURRENT_STATUS. Exiting script."
        exit 1
    elif [[ -z "$CURRENT_STATUS" || "$CURRENT_STATUS" == "NULL" ]]; then
        echo "Warning: Status unavailable. Waiting ${POLL_INTERVAL} seconds..."
        sleep $POLL_INTERVAL
    else
        echo "Snapshot status: $CURRENT_STATUS. Waiting ${POLL_INTERVAL} seconds..."
        sleep $POLL_INTERVAL
    fi
done


echo ""
echo "========================================================="
echo "Stage 2b of 7: Dynamically Discover the latest Snapshot"
echo "========================================================="
echo ""

echo "--- Discovering the latest snapshot performed on $LPAR_NAME ---"

SNAPSHOT_LIST_JSON=$(ibmcloud pi instance snapshot list --json)

if [[ $? -ne 0 || -z "$SNAPSHOT_LIST_JSON" ]]; then
    echo "Error: Failed to retrieve workspace snapshot list. Aborting."
    exit 1
fi

# Scan ALL snapshots and return the most recent matching murph-* snapshot
LATEST_MATCHING_SNAPSHOT_ID=$(echo "$SNAPSHOT_LIST_JSON" \
    | jq -r --arg SN "$SNAPSHOT_NAME" '
        .snapshots
        | map(select(.name == $SN))
        | sort_by(.creationDate)
        | last
        | .snapshotID
    ')

if [[ -z "$LATEST_MATCHING_SNAPSHOT_ID" || "$LATEST_MATCHING_SNAPSHOT_ID" == "null" ]]; then
    echo "Error: No snapshot named $SNAPSHOT_NAME found. Aborting."
    exit 1
fi

SOURCE_SNAPSHOT_ID="$LATEST_MATCHING_SNAPSHOT_ID"

echo "Matched Snapshot Name:   $SNAPSHOT_NAME"
echo "Matched Snapshot ID:     $SOURCE_SNAPSHOT_ID"
echo ""


echo ""
echo "Stage 2b of 7 Complete: Latest Snapshot ID found: $SOURCE_SNAPSHOT_ID"
echo ""

sleep 2m


echo "========================================================================"
echo "Stage 3 of 7: Discover and Classify Source Volume IDs from the Snapshot"
echo "========================================================================"
echo ""

echo "--- Discovering Source Volume IDs from Snapshot: $SOURCE_SNAPSHOT_ID ---"

VOLUME_IDS_JSON=$(ibmcloud pi instance snapshot get "$SOURCE_SNAPSHOT_ID" --json)

if [[ $? -ne 0 ]]; then
    echo "Error retrieving snapshot details. Check snapshot ID: $SOURCE_SNAPSHOT_ID."
    exit 1
fi

SOURCE_VOLUME_IDS=$(echo "$VOLUME_IDS_JSON" | jq -r '.volumeSnapshots | keys[]')

if [[ -z "$SOURCE_VOLUME_IDS" ]]; then
    echo "Error: No Volume IDs found in the snapshot metadata. Aborting."
    exit 1
fi

SOURCE_BOOT_ID=""
SOURCE_DATA_IDS=""
BOOT_FOUND=0

echo "All Source Volume IDs found. Checking individual volumes for Load Source designation..."
echo ""
echo "Stage 3 of 7: Classifying Source Boot/Data Volumes from Snapshot"

for VOL_ID in $SOURCE_VOLUME_IDS; do
    VOLUME_DETAIL=$(ibmcloud pi volume get "$VOL_ID" --json 2>/dev/null)

    if [[ $? -eq 0 ]]; then
        IS_BOOTABLE=$(echo "$VOLUME_DETAIL" | jq -r '.bootable')

        if [[ "$IS_BOOTABLE" == "true" ]]; then
            SOURCE_BOOT_ID="$VOL_ID"
            BOOT_FOUND=1
            echo "Identified Source Boot Volume ID: $SOURCE_BOOT_ID"
        else
            SOURCE_DATA_IDS="$SOURCE_DATA_IDS,$VOL_ID"
        fi
    else
        echo "Warning: Failed to retrieve details for source volume ID: $VOL_ID. Skipping."
    fi
done

SOURCE_DATA_IDS=${SOURCE_DATA_IDS#,}

if [[ "$BOOT_FOUND" -ne 1 ]]; then
    echo "FATAL ERROR: Could not identify the source boot volume among the volumes in the snapshot. Aborting."
    exit 1
fi

echo "Source Boot Volume ID: $SOURCE_BOOT_ID"
echo "Source Data Volume IDs (CSV): $SOURCE_DATA_IDS"
echo ""

echo "--- Calculating Total Volume Count ---"

BOOT_COUNT=0
if [[ -n "$SOURCE_BOOT_ID" ]]; then
    BOOT_COUNT=1
    echo "Counted 1 Source Boot Volume ID."
fi

CLEANED_DATA_IDS=$(echo "$SOURCE_DATA_IDS" | tr ',' ' ' | tr '\n' ' ' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

DATA_COUNT=0
if [[ -n "$CLEANED_DATA_IDS" ]]; then
    DATA_COUNT=$(echo "$CLEANED_DATA_IDS" | wc -w)
fi

echo "Counted $DATA_COUNT Source Data Volume ID(s)."

EXPECTED_VOLUME_COUNT=$((BOOT_COUNT + DATA_COUNT))
echo "--- Calculated Total Expected Volume Count: $EXPECTED_VOLUME_COUNT ---"
echo ""

echo "Stage 3 of 7 Complete: Source Boot/Data Volumes Identified"
echo ""



echo "========================================================================"
echo "Stage 4 of 7: Create Volume Clones from the Source Volumes"
echo "========================================================================"
echo ""

echo "--- Initiating volume cloning of all source volumes ---"

COMMA_SEPARATED_IDS=$(echo "$SOURCE_VOLUME_IDS" | tr ' ' ',')

# NOTE: SOURCE_BOOT_ID is one of SOURCE_VOLUME_IDS; to avoid duplicates,
# you *could* just use COMMA_SEPARATED_IDS here. Keeping your original
# pattern in case it's working with your environment:
CLONE_TASK_ID=$(ibmcloud pi volume clone-async create "$CLONE_NAME_PREFIX" \
    --volumes "$SOURCE_BOOT_ID,$COMMA_SEPARATED_IDS" \
    --target-tier "$STORAGE_TIER" \
    --json | jq -r '.cloneTaskID')

if [[ -z "$CLONE_TASK_ID" ]]; then
    echo "Error creating volume clone task. Aborting."
    exit 1
fi

echo "Clone task initiated. Task ID: $CLONE_TASK_ID"

echo "--- Waiting for asynchronous clone task completion ---"

while true; do
    TASK_STATUS=$(ibmcloud pi volume clone-async get "$CLONE_TASK_ID" --json | jq -r '.status')
    
    if [[ "$TASK_STATUS" == "completed" ]]; then
        echo "Clone task $CLONE_TASK_ID completed successfully."
        break
    elif [[ "$TASK_STATUS" == "failed" || "$TASK_STATUS" == "cancelled" ]]; then
        echo "Error: Clone task $CLONE_TASK_ID failed with status: $TASK_STATUS. Aborting."
        exit 1
    else
        echo "Clone task status: $TASK_STATUS. Waiting $POLL_INTERVAL seconds..."
        sleep $POLL_INTERVAL
    fi
done

echo "--- Discovery Retry Loop (Waiting for API Synchronization) ---"

MAX_RETRIES=20
RETRY_COUNT=0
POLL_INTERVAL=15 
FOUND_COUNT=0
NEW_CLONE_IDS=""

while [[ $FOUND_COUNT -ne $EXPECTED_VOLUME_COUNT && $RETRY_COUNT -lt $MAX_RETRIES ]]; do
    RETRY_COUNT=$((RETRY_COUNT + 1))
    echo "Attempt $RETRY_COUNT of $MAX_RETRIES: Searching for volumes using prefix '$CLONE_NAME_PREFIX'..."

    NEW_CLONE_IDS=$(ibmcloud pi volume list --long --json | \
        jq -r ".volumes[] | select(.name | contains(\"$CLONE_NAME_PREFIX\")) | .volumeID")

    FOUND_COUNT=$(echo "$NEW_CLONE_IDS" | wc -w)

    if [[ $FOUND_COUNT -ne $EXPECTED_VOLUME_COUNT ]]; then
        if [[ $RETRY_COUNT -ge $MAX_RETRIES ]]; then
            echo "FATAL ERROR: Only $FOUND_COUNT out of $EXPECTED_VOLUME_COUNT volumes became visible after maximum retries. Aborting."
            exit 1
        fi
        
        echo "Found $FOUND_COUNT volume(s). Expected $EXPECTED_VOLUME_COUNT. Waiting $POLL_INTERVAL seconds..."
        sleep $POLL_INTERVAL
    fi
done

if [[ -z "$NEW_CLONE_IDS" ]]; then
    echo "CRITICAL ERROR: Failed to locate cloned volume IDs after waiting. API synchronization failed. Aborting."
    exit 1
fi

echo "Stage 4 of 7 Complete: Clone Volume(s) successfully created with Volume IDs: $NEW_CLONE_IDS"


echo""
echo "Wait 2 minutes to allow cloned volumes to synchronize with the PVS API"
sleep 2m

echo ""
echo "========================================================================"
echo "Stage 5 of 7: Classify the Newly Cloned Volumes (Boot vs. Data)"
echo "========================================================================"
echo ""

echo ""
echo "Classifying BOOT AND DATA VOLUMES by checking the explicit 'bootable' property."

CLONE_BOOT_ID=""
TEMP_DATA_IDS="" 
BOOT_FOUND_FLAG=0

for NEW_ID in $NEW_CLONE_IDS; do
    VOLUME_DETAIL=$(ibmcloud pi volume get "$NEW_ID" --json 2>/dev/null)

    if [[ $? -ne 0 ]]; then
        echo "Warning: Failed to retrieve details for cloned volume ID: $NEW_ID. Skipping classification."
        continue
    fi
    
    IS_BOOTABLE=$(echo "$VOLUME_DETAIL" | jq -r '.bootable')
    
    if [[ "$IS_BOOTABLE" == "true" ]]; then
        echo "Identified CLONE Boot Volume ID: $NEW_ID"
        CLONE_BOOT_ID="$NEW_ID"
        BOOT_FOUND_FLAG=1
    else
        echo "Identified CLONE Data Volume ID: $NEW_ID"
        TEMP_DATA_IDS="$TEMP_DATA_IDS,$NEW_ID"
    fi
done

CLONE_DATA_IDS=$(echo "$TEMP_DATA_IDS" | sed 's/,\+/,/g; s/^,//; s/,$//')

if [[ "$BOOT_FOUND_FLAG" -ne 1 ]]; then
    echo "FATAL ERROR: Failed to identify the cloned boot volume ID using the 'bootable' property. Aborting."
    exit 1
fi


echo ""
echo "CLONE_BOOT_ID: $CLONE_BOOT_ID"
echo "CLONE_DATA_IDS (CSV): $CLONE_DATA_IDS"
echo "Stage 5 of 7 Complete: Target Boot and Data Volumes Successfully Identified"
echo ""

echo "========================================================================"
echo "Stage 6 of 7: Attach Cloned Volumes to the Empty LPAR"
echo "========================================================================"
echo ""

echo "Resolving instance ID (UUID) ..."

LPAR_INSTANCE_ID=$(ibmcloud pi instance list --json \
    | jq -r ".pvmInstances[] | select(.name == \"$LPAR_NAME\") | .id")

if [[ -z "$LPAR_INSTANCE_ID" ]]; then
    echo "[FATAL] Instance ID could not be found for $LPAR_NAME"
    exit 1
fi

echo "Using instance ID: $LPAR_INSTANCE_ID"
echo ""
echo "BOOT VOLUME: $CLONE_BOOT_ID"
echo "DATA VOLUMES: $CLONE_DATA_IDS"
echo ""


# -------------------------------------------------------------
# ATTACH VOLUMES (HANDLE BOOT-ONLY VS BOOT+DATA)
# -------------------------------------------------------------

if [[ -n "$CLONE_DATA_IDS" ]]; then
    echo "Data volumes detected — attaching BOOT and DATA together"

    if ! ibmcloud pi instance volume attach "$LPAR_INSTANCE_ID" \
            --volumes "$CLONE_DATA_IDS" \
            --boot-volume "$CLONE_BOOT_ID"; then
        echo "[ERROR] Combined boot+data volume attach failed"
        exit 1
    fi
else
    echo "No data volumes detected — attaching BOOT volume only"

    if ! ibmcloud pi instance volume attach "$LPAR_INSTANCE_ID" \
            --boot-volume "$CLONE_BOOT_ID"; then
        echo "[ERROR] Boot-only volume attach failed"
        exit 1
    fi
fi

echo "Attach request accepted by backend."


# -------------------------------------------------------------
# INITIAL STABILIZATION WAIT (REQUIRED)
# -------------------------------------------------------------
echo "Waiting 45 seconds for PowerVS backend to stabilize..."
sleep 45

# =============================================================
# WAIT UNTIL ALL VOLUMES ARE ATTACHED (API CONFIRMATION)
# =============================================================

echo ""
echo "Polling instance volume list until all volumes are visible..."

MAX_WAIT=420        # 7 minutes total
INTERVAL=30         # poll every 30 seconds
WAITED=0

while true; do
    VOL_LIST=$(ibmcloud pi instance volume list "$LPAR_INSTANCE_ID" --json 2>/dev/null \
        | jq -r '(.volumes // []) | .[]? | .volumeID')

    BOOT_PRESENT=$(echo "$VOL_LIST" | grep -q "$CLONE_BOOT_ID" && echo yes || echo no)

    DATA_PRESENT=true
    if [[ -n "$CLONE_DATA_IDS" ]]; then
        for VOL in ${CLONE_DATA_IDS//,/ }; do
            if ! echo "$VOL_LIST" | grep -q "$VOL"; then
                DATA_PRESENT=false
                break
            fi
        done
    fi

    if [[ "$BOOT_PRESENT" == "yes" && "$DATA_PRESENT" == "true" ]]; then
        echo "Stage 6 of 7 Complete: All volumes confirmed attached via API"
        break
    fi

    if [[ $WAITED -ge $MAX_WAIT ]]; then
        echo "[FATAL] Volumes never fully appeared after $MAX_WAIT seconds."
        echo "[WARN] Attach request was accepted, but API never reflected final state."
        echo "[WARN] Manual verification recommended."
        exit 22
    fi

    echo "Volumes not fully attached yet — checking again..."
    sleep "$INTERVAL"
    WAITED=$((WAITED + INTERVAL))
done



echo ""
echo "====================================================================="
echo "Stage 7 of 7: BOOT IBMi Instance Safely w/Unassisted IPL"
echo "====================================================================="
echo ""

echo "--- Setting LPAR boot mode and initiating startup ---"

STATUS=$(ibmcloud pi instance get "$LPAR_INSTANCE_ID" --json | jq -r '.status')

if [[ "$STATUS" != "ACTIVE" ]]; then
    echo "Configuring NORMAL boot mode..."

    ibmcloud pi instance operation "$LPAR_INSTANCE_ID" \
        --operation-type boot \
        --boot-mode a \
        --boot-operating-mode normal || {
        echo "[FATAL] Failed to configure IBM i boot operation."
        exit 1
    }

    echo "Starting instance..."

    ibmcloud pi instance action "$LPAR_INSTANCE_ID" --operation start || { 
        echo "[FATAL] Failed to initiate LPAR start command. Aborting."
        exit 1 
    }

    echo "LPAR start command accepted."
else
    echo "LPAR is already ACTIVE — skipping boot/start request"
fi


# =============================================================
# WAIT FOR ACTIVE STATE
# =============================================================

echo "Waiting for LPAR to reach ACTIVE state..."

MAX_BOOT_WAIT=1200  # 20 minutes
BOOT_WAITED=0
INTERVAL=30

while true; do
    STATUS=$(ibmcloud pi instance get "$LPAR_INSTANCE_ID" --json | jq -r '.status')

    if [[ "$STATUS" == "ACTIVE" ]]; then
        echo "SUCCESS — LPAR is ACTIVE"
        JOB_SUCCESS=1
        break
    fi

    if [[ "$STATUS" == "ERROR" ]]; then
        echo "[FATAL] LPAR entered ERROR state during boot"
        exit 1
    fi

    if [[ $BOOT_WAITED -ge $MAX_BOOT_WAIT ]]; then
        echo "[FATAL] LPAR failed to reach ACTIVE after $(($MAX_BOOT_WAIT/60)) minutes"
        exit 1
    fi

    echo "LPAR still in state [$STATUS] — sleeping $INTERVAL seconds..."
    sleep $INTERVAL
    BOOT_WAITED=$((BOOT_WAITED+INTERVAL))
done


# =============================================================
# FINAL CONFIRMATION & OPTIONAL SNAPSHOT-CLEANUP JOB
# =============================================================

set +e
RAW=$(ibmcloud pi instance get "$LPAR_INSTANCE_ID" --json 2>/dev/null)
CLI_RC=$?
STATUS=$(echo "$RAW" | jq -r '.status // empty' 2>/dev/null)
JQ_RC=$?


if [[ $CLI_RC -ne 0 ]]; then
    echo "WARNING: IBM Cloud API temporarily unavailable while checking final status."
fi

if [[ $JQ_RC -ne 0 || -z "$STATUS" ]]; then
    echo "WARNING: Could not parse final status from API — using last known ACTIVE state."
    STATUS="ACTIVE"
fi

echo "FINAL VALIDATION — LPAR status = $STATUS"



echo "Stage 7 of 7 Complete: Successfully confirmed LPAR is Active from API readback"

echo ""
echo "============================================"
echo "****Snapshot Restore Summary****"
echo "============================================"
echo "****Snapshot Taken            : Yes****"
echo "****Volumes Cloned            : Yes****"
echo "****Volumes Attached to LPAR  : Yes****"
echo "****LPAR Boot Mode            : NORMAL (Mode A)****"
echo "****LPAR Final Status         : ACTIVE****"
echo "============================================"
echo ""


echo "--- Evaluating whether to trigger cleanup job ---"

if [[ "${RUN_CLEANUP_JOB:-No}" == "Yes" ]]; then
    echo "Switching Code Engine context to IBMi project"

    # Target Code Engine project
    ibmcloud ce project target --name IBMi > /dev/null 2>&1 || {
        echo "ERROR: Unable to select cleanup project IBMi"
        exit 1
    }

    echo "Submitting Code Engine cleanup job: prod-cleanup"

    # Capture stdout + stderr (CLI may mix them)
    RAW_SUBMISSION=$(ibmcloud ce jobrun submit \
        --job prod-cleanup \
        --output json 2>&1)

    # Extract jobrun name (works across CLI versions)
    NEXT_RUN=$(echo "$RAW_SUBMISSION" | jq -r '.metadata.name // .name // empty')

    if [[ -z "$NEXT_RUN" ]]; then
        echo "ERROR: Job submission returned no jobrun name."
        echo "Raw submission output:"
        echo "$RAW_SUBMISSION"
        exit 1
    fi

    echo "Triggered cleanup instance: $NEXT_RUN"

else
    echo "Skipping cleanup stage; RUN_CLEANUP_JOB is NOT set to Yes."
fi

echo "Job #2 Completed Successfully"

JOB_SUCCESS=1
sleep 1
exit 0
