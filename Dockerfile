# Use a lightweight Debian base image
FROM debian:stable-slim

# Set non-interactive mode for smooth dependency installation
ENV DEBIAN_FRONTEND=noninteractive

# Set HOME and working directory
ENV HOME=/root
WORKDIR ${HOME}

# -----------------------------------------------------------
# 1. Install Dependencies (curl, jq, and bash)
# -----------------------------------------------------------
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
    curl \
    jq \
    bash \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# -----------------------------------------------------------
# 2. Install IBM Cloud CLI and PowerVS Plugin
# -----------------------------------------------------------

# Install the IBM Cloud CLI core utility [1]
RUN curl -fsSL https://clis.cloud.ibm.com/install/linux | bash 

# Install the Power Virtual Server (Power-IaaS) CLI plugin [2]
RUN ibmcloud plugin install power-iaas -f

# -----------------------------------------------------------
# 3. Add Script and Set Permissions
# -----------------------------------------------------------

# Copy the restoration shell script (named run.sh)
COPY run.sh /usr/local/bin/run.sh

# Ensure the script is executable
RUN chmod +x /usr/local/bin/run.sh

# -----------------------------------------------------------
# 4. Define Execution Command
# -----------------------------------------------------------

# Set the entry point to run the script.
ENTRYPOINT ["/usr/local/bin/run.sh"]
