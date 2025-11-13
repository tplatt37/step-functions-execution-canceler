#!/bin/bash

# Script to cancel old Step Functions executions
# Usage: ./cancel-old-executions.sh --state-machine-arn <arn> --batch-size <num> --age-hours <num> --sleep-seconds <num> [--clean]

set -e

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Function to display usage
usage() {
    echo "Usage: $0 --state-machine-arn <arn> --batch-size <num> --age-hours <num> --sleep-seconds <num> [--clean]"
    echo ""
    echo "Parameters:"
    echo "  --state-machine-arn <arn> : ARN of the Step Functions state machine (required)"
    echo "  --batch-size <num>        : Number of executions to retrieve per page (required)"
    echo "  --age-hours <num>         : Age threshold in hours - executions older than this will be targeted (required)"
    echo "  --sleep-seconds <num>     : Number of seconds to sleep between processing pages (required)"
    echo "  --clean                   : Flag to actually stop the executions (optional, without this it's a dry run)"
    echo ""
    echo "Example:"
    echo "  $0 --state-machine-arn arn:aws:states:us-east-1:123456789:stateMachine:MyMachine --batch-size 50 --age-hours 24 --sleep-seconds 2"
    echo "  $0 --state-machine-arn arn:aws:states:us-east-1:123456789:stateMachine:MyMachine --batch-size 50 --age-hours 24 --sleep-seconds 2 --clean"
    exit 1
}

# Initialize variables
STATE_MACHINE_ARN=""
BATCH_SIZE=""
AGE_HOURS=""
SLEEP_SECONDS=""
CLEAN_MODE=false

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --state-machine-arn)
            STATE_MACHINE_ARN="$2"
            shift 2
            ;;
        --batch-size)
            BATCH_SIZE="$2"
            shift 2
            ;;
        --age-hours)
            AGE_HOURS="$2"
            shift 2
            ;;
        --sleep-seconds)
            SLEEP_SECONDS="$2"
            shift 2
            ;;
        --clean)
            CLEAN_MODE=true
            shift
            ;;
        -h|--help)
            usage
            ;;
        *)
            echo -e "${RED}Error: Unknown parameter: $1${NC}"
            usage
            ;;
    esac
done

# Check if required parameters are provided
if [ -z "$STATE_MACHINE_ARN" ]; then
    echo -e "${RED}Error: --state-machine-arn is required${NC}"
    usage
fi

if [ -z "$BATCH_SIZE" ]; then
    echo -e "${RED}Error: --batch-size is required${NC}"
    usage
fi

if [ -z "$AGE_HOURS" ]; then
    echo -e "${RED}Error: --age-hours is required${NC}"
    usage
fi

if [ -z "$SLEEP_SECONDS" ]; then
    echo -e "${RED}Error: --sleep-seconds is required${NC}"
    usage
fi

# Validate numeric parameters
if ! [[ "$BATCH_SIZE" =~ ^[0-9]+$ ]]; then
    echo -e "${RED}Error: batch-size must be a positive integer${NC}"
    exit 1
fi

if ! [[ "$AGE_HOURS" =~ ^[0-9]+$ ]]; then
    echo -e "${RED}Error: age-hours must be a positive integer${NC}"
    exit 1
fi

if ! [[ "$SLEEP_SECONDS" =~ ^[0-9]+$ ]]; then
    echo -e "${RED}Error: sleep-seconds must be a positive integer${NC}"
    exit 1
fi

# Check if AWS CLI is installed
if ! command -v aws &> /dev/null; then
    echo -e "${RED}Error: AWS CLI is not installed${NC}"
    exit 1
fi

# Check if jq is installed
if ! command -v jq &> /dev/null; then
    echo -e "${RED}Error: jq is not installed (required for JSON processing)${NC}"
    exit 1
fi

echo "=========================================="
echo "Step Functions Execution Canceler"
echo "=========================================="
echo "State Machine ARN: $STATE_MACHINE_ARN"
echo "Batch Size: $BATCH_SIZE"
echo "Age Threshold: $AGE_HOURS hours"
echo "Sleep Between Pages: $SLEEP_SECONDS seconds"
if [ "$CLEAN_MODE" = true ]; then
    echo -e "Mode: ${RED}CLEAN MODE - Will stop executions${NC}"
else
    echo -e "Mode: ${YELLOW}DRY RUN - Will only list executions${NC}"
fi
echo "=========================================="
echo ""

# Calculate the timestamp threshold (current time - age hours)
CURRENT_TIMESTAMP=$(date +%s)
THRESHOLD_TIMESTAMP=$((CURRENT_TIMESTAMP - (AGE_HOURS * 3600)))
THRESHOLD_DATE=$(date -r $THRESHOLD_TIMESTAMP +"%Y-%m-%d %H:%M:%S")

echo "Current time: $(date +"%Y-%m-%d %H:%M:%S")"
echo "Threshold time: $THRESHOLD_DATE"
echo "Looking for executions older than: $THRESHOLD_DATE"
echo ""

# Counters
TOTAL_CHECKED=0
TOTAL_OLD=0
TOTAL_STOPPED=0
PAGE_COUNT=0
NEXT_TOKEN=""

# Main loop to process pages
while true; do
    PAGE_COUNT=$((PAGE_COUNT + 1))
    echo -e "${GREEN}Processing page $PAGE_COUNT...${NC}"
    
    # Build the AWS CLI command
    if [ -z "$NEXT_TOKEN" ]; then
        # First page
        RESPONSE=$(aws stepfunctions list-executions \
            --state-machine-arn "$STATE_MACHINE_ARN" \
            --status-filter RUNNING \
            --max-results "$BATCH_SIZE" \
            --output json 2>&1)
    else
        # Subsequent pages
        RESPONSE=$(aws stepfunctions list-executions \
            --state-machine-arn "$STATE_MACHINE_ARN" \
            --status-filter RUNNING \
            --max-results "$BATCH_SIZE" \
            --next-token "$NEXT_TOKEN" \
            --output json 2>&1)
    fi
    
    # Check if the command was successful
    if [ $? -ne 0 ]; then
        echo -e "${RED}Error calling AWS API:${NC}"
        echo "$RESPONSE"
        exit 1
    fi
    
    # Parse the response
    EXECUTIONS=$(echo "$RESPONSE" | jq -r '.executions')
    
    if [ "$EXECUTIONS" == "null" ] || [ "$EXECUTIONS" == "[]" ]; then
        echo "No more executions found on this page."
        break
    fi
    
    # Count executions on this page
    EXECUTION_COUNT=$(echo "$EXECUTIONS" | jq 'length')
    echo "Found $EXECUTION_COUNT running executions on this page."
    TOTAL_CHECKED=$((TOTAL_CHECKED + EXECUTION_COUNT))
    
    # Process each execution
    for i in $(seq 0 $((EXECUTION_COUNT - 1))); do
        EXECUTION=$(echo "$EXECUTIONS" | jq -r ".[$i]")
        EXECUTION_ARN=$(echo "$EXECUTION" | jq -r '.executionArn')
        START_DATE=$(echo "$EXECUTION" | jq -r '.startDate')
        
        # Convert start date to timestamp (AWS returns ISO 8601 format)
        # Extract just the timestamp portion (before the milliseconds)
        START_TIMESTAMP=$(date -j -f "%Y-%m-%dT%H:%M:%S" "$(echo $START_DATE | cut -d'.' -f1)" +%s 2>/dev/null || echo "0")
        
        if [ "$START_TIMESTAMP" -eq 0 ]; then
            echo -e "${YELLOW}Warning: Could not parse start date for execution${NC}"
            continue
        fi
        
        # Check if execution is older than threshold
        if [ "$START_TIMESTAMP" -lt "$THRESHOLD_TIMESTAMP" ]; then
            TOTAL_OLD=$((TOTAL_OLD + 1))
            AGE_SECONDS=$((CURRENT_TIMESTAMP - START_TIMESTAMP))
            AGE_HOURS_CALC=$((AGE_SECONDS / 3600))
            
            echo -e "  ${YELLOW}Old execution found (age: ${AGE_HOURS_CALC}h):${NC}"
            echo "    ARN: $EXECUTION_ARN"
            echo "    Started: $START_DATE"
            
            # Stop the execution if in clean mode
            if [ "$CLEAN_MODE" = true ]; then
                echo -e "    ${RED}Stopping execution...${NC}"
                STOP_RESULT=$(aws stepfunctions stop-execution \
                    --execution-arn "$EXECUTION_ARN" \
                    --error "CancelledByScript" \
                    --cause "Execution older than $AGE_HOURS hours" \
                    --output json 2>&1)
                
                if [ $? -eq 0 ]; then
                    TOTAL_STOPPED=$((TOTAL_STOPPED + 1))
                    echo -e "    ${GREEN}✓ Stopped successfully${NC}"
                else
                    echo -e "    ${RED}✗ Failed to stop:${NC} $STOP_RESULT"
                fi
            fi
        fi
    done
    
    # Check if there are more pages
    NEXT_TOKEN=$(echo "$RESPONSE" | jq -r '.nextToken // empty')
    
    if [ -z "$NEXT_TOKEN" ]; then
        echo "No more pages to process."
        break
    fi
    
    # Sleep before processing next page to avoid throttling
    echo "Sleeping for $SLEEP_SECONDS seconds before next page..."
    echo ""
    sleep "$SLEEP_SECONDS"
done

# Print summary
echo ""
echo "=========================================="
echo "Summary"
echo "=========================================="
echo "Total pages processed: $PAGE_COUNT"
echo "Total executions checked: $TOTAL_CHECKED"
echo "Total old executions found: $TOTAL_OLD"
if [ "$CLEAN_MODE" = true ]; then
    echo -e "Total executions stopped: ${RED}$TOTAL_STOPPED${NC}"
else
    echo -e "${YELLOW}DRY RUN - No executions were stopped${NC}"
    echo "Run with --clean flag to actually stop executions"
fi
echo "=========================================="
