This automation script is designed to execute the post-provisioning steps to execute the snapshot/clone process for the purposes of performing a backup operation leveraging IBM CLoud Code Engine.  It is part 2 of 3 in the series.  This script starts exactly where the part 1 (pvs-api-deploy) script ended with the empty IBMi LPAR already provisioned and in the shutoff state.


Required Utilities for Dockerfile:

-ibmcloud CLI and the power-iaas plugin.
-jq for JSON processing.

Script Outline

1.  Define Environment Variables
2.  Cleanup Function for Failures
3.  Login Authentication to IBM Cloud
4.  Create Snapshot on Source LPAR
5.  Discover Snapshot in Account
6.  Identify Source Volumes in Snapshot
7.  Classify Source Volumes (Boot vs. Data)
8.  Create Volume Clones
9.  Clasify the Newly Clones Volumes (Boot vs. Data)
10. Attach Cloned Volumes to the Empty LPAR
11. Polling and Status Verification prior to Boot
12. Setting LPAR Boot Mood and Startup Initializaing 
13. LPAR Status Verification (Active)
