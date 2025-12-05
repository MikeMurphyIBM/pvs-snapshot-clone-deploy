This automation script is designed to execute the post-provisioning steps for migrating an IBM i workload via snapshot restoration for the purposes of performing a backup operation, and is 2 of 3 in the series.  It starts exactly where the part 1 (pvs-api-deploy) script ended: with the empty IBMi LPAR already provisioned and in the shutoff state.
The script dynamically discovers the volumes within the provided snapshot, clones them, attaches the cloned volumes (including the new boot volume) 
to the LPAR, and initiates an unattended (Normal mode) boot.
Required Utilities
This script requires:
-ibmcloud CLI and the power-iaas plugin.
-jq for JSON processing.

Script Outline

1.  Environment Variables
2.  Cleanup Function
3.  Login Inititialization
4.  Create Snapshot on Source LPAR
5.  Discover Snapshot in Account
6.  Identify Source Volumes in Snapshot
7.  Classify Source Volumes (Boot vs. Data)
8.  Create Volume Clones
9.  Clasify the Newly Clones Volumes (Boot vs. Data)
10. Attach Cloned Volumes to the Empty LPAR
11. Polling and Status Verification prior to Boot
12. Setting LPAR Boot Mood and Initializaing Startup
13. Verify LPAR Status is Active 
