#!/bin/bash

# Exit immediately if a command exits with a non-zero status.
set -e

# ----------------------------
# Configuration and Variables
# ----------------------------

# Function to display usage information
usage() {
    echo "Usage: $0 -p <splunk-pod-name> [-n <namespace>] [-c <cpu_limit>] [-m <memory_limit>]"
    echo
    echo "Options:"
    echo "  -p, --pod          Splunk pod name (required)"
    echo "  -n, --namespace    Kubernetes namespace (default: default)"
    echo "  -c, --cpu-limit    CPU limit for the Splunk pod (default: 500m)"
    echo "  -m, --memory-limit Memory limit for the Splunk pod (default: 1Gi)"
    echo "  -h, --help         Display this help message"
    exit 1
}

# Default values
NAMESPACE="default"
CPU_LIMIT="500m"
MEMORY_LIMIT="1Gi"
SPLUNK_POD_NAME=""
SPLUNK_LABEL="app.kubernetes.io/name=cluster-manager"
# Parse command-line arguments
while [[ "$#" -gt 0 ]]; do
    case $1 in
        -p|--pod)
            SPLUNK_POD_NAME="$2"
            shift 2
            ;;
        -n|--namespace)
            NAMESPACE="$2"
            shift 2
            ;;
        -c|--cpu-limit)
            CPU_LIMIT="$2"
            shift 2
            ;;
        -m|--memory-limit)
            MEMORY_LIMIT="$2"
            shift 2
            ;;
        -h|--help)
            usage
            ;;
        *)
            echo "Unknown parameter passed: $1"
            usage
            ;;
    esac
done

# Check if the Splunk pod name is provided
if [[ -z "$SPLUNK_POD_NAME" ]]; then
    echo "Error: Splunk pod name is required."
    usage
fi

# ----------------------------
# Functions
# ----------------------------

# Function to handle errors
error_exit() {
    echo "Error: $1"
    exit 1
}

# Function to execute Splunk CLI commands using kubectl-splunk exec mode
splunk_exec() {
    local cmd="$1"
    kubectl splunk -vvv --namespace "$NAMESPACE" --selector "$SPLUNK_LABEL" -P "$SPLUNK_POD_NAME" exec $cmd
}

# Function to execute Splunk REST API calls using kubectl-splunk rest mode
splunk_rest() {
    local method="$1"
    local endpoint="$2"
    shift 2
    kubectl splunk --namespace "$NAMESPACE" rest "$method" "$endpoint" "$@"
}

# ----------------------------
# Prerequisite Checks
# ----------------------------

# Ensure kubectl is installed
if ! command -v kubectl &> /dev/null; then
    error_exit "kubectl could not be found. Please install it and ensure it's in your PATH."
fi

# Ensure kubectl-splunk is installed
if ! command -v kubectl-splunk &> /dev/null; then
    error_exit "kubectl-splunk could not be found. Please install it from PyPI using 'pip install kubectl-splunk'."
fi

# ----------------------------
# Main Workflow
# ----------------------------

echo "Starting Splunk management operations on pod: $SPLUNK_POD_NAME in namespace: $NAMESPACE"

# 1. Set Pod Resource Limits
echo "Setting pod resource limits..."

# 2. Enable Workload Management
echo "Enabling Workload Management in Splunk..."
splunk_exec "enable workload-management --accept-license --answer-yes --no-prompt"

# 3. Create Workload Pools using REST API
echo "Creating workload pools..."
splunk_rest POST /services/workload/pools \
    --data "name=high_priority_pool" \
    --data "cpu_weight=80" \
    --data "mem_weight=80"

splunk_rest POST /services/workload/pools \
    --data "name=low_priority_pool" \
    --data "cpu_weight=20" \
    --data "mem_weight=20"

# 4. Create Workload Rules using REST API
echo "Creating workload rules..."
splunk_rest POST /services/workload/rules \
    --data "name=high_priority_rule" \
    --data "workload_pool=high_priority_pool" \
    --data "search_filter=(index=critical_data)"

splunk_rest POST /services/workload/rules \
    --data "name=low_priority_rule" \
    --data "workload_pool=low_priority_pool" \
    --data "search_filter=(index=non_critical_data)"

# 5. Run Test Searches
echo "Running test searches to generate workload..."
# High-priority search
splunk_exec "/opt/splunk/bin/splunk search 'search index=critical_data | head 10000' -app search -auth admin:changeme &"

# Low-priority search
splunk_exec "/opt/splunk/bin/splunk search 'search index=non_critical_data | head 10000' -app search -auth admin:changeme &"

# Wait for searches to execute
echo "Allowing searches to run for 60 seconds..."
sleep 60

# 6. Monitor Resource Usage
echo "Collecting resource usage data..."
kubectl top pod "$SPLUNK_POD_NAME" -n "$NAMESPACE"

# Optional: Detailed resource usage
echo "Fetching detailed CPU and memory usage..."
splunk_exec "ps aux --sort=-%cpu | head -n 5"

# 7. Verify Workload Management Status
echo "Verifying Workload Management status..."
splunk_exec "/opt/splunk/bin/splunk show workload-management-status"

# 8. Cleanup
echo "Cleaning up created workload pools and rules..."
splunk_rest DELETE /services/workload/rules/high_priority_rule
splunk_rest DELETE /services/workload/rules/low_priority_rule
splunk_rest DELETE /services/workload/pools/high_priority_pool
splunk_rest DELETE /services/workload/pools/low_priority_pool

# Disable Workload Management
echo "Disabling Workload Management..."
splunk_exec "/opt/splunk/bin/splunk disable workload-management --answer-yes --no-prompt"

echo "Splunk management operations completed successfully."
