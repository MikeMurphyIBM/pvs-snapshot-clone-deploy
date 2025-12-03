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
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    ca-certificates \
    jq

# -----------------------------------------------------------
# Install IBM Cloud CLI and Power Virtual Server (Power-IaaS) Plugin
# This step is COMBINED (using '&&') into a single RUN instruction.
# This ensures that the shell environment where the IBM Cloud CLI is installed 
# immediately proceeds to install the plugin, resolving the 'ibmcloud: not found' error.
# -----------------------------------------------------------
RUN curl -fsSL https://clis.cloud.ibm.com/install/linux | bash && \
    ibmcloud plugin install power-iaas -f

# -----------------------------------------------------------
# 2. Add Runtime Script and Define Entrypoint
# -----------------------------------------------------------
# Copy the executable script into the working directory
COPY run.sh .

# Ensure the script is executable
RUN chmod +x run.sh

# Define the command to execute when the container starts
CMD ["/root/run.sh"]
