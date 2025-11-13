# Step Functions Execution Canceler

This repository contains tools to manage and cancel old AWS Step Functions executions, along with a test state machine for validation.


AI Disclaimer: GENERATED WITH CLINE and Anthropic Sonnet 4.5



## Contents

1. **cancel-old-executions.sh** - Bash script to identify and optionally stop old running Step Functions executions
2. **test-statemachine.yaml** - CloudFormation template for a test state machine that simulates long-running executions

## Prerequisites

- AWS CLI installed and configured with appropriate credentials
- `jq` command-line JSON processor installed
- Appropriate AWS IAM permissions:
  - `states:ListExecutions`
  - `states:StopExecution`
  - For CloudFormation deployment: `cloudformation:*`, `states:*`, `iam:*`, `logs:*`

### Installing jq

**macOS:**
```bash
brew install jq
```

**Linux (Ubuntu/Debian):**
```bash
sudo apt-get install jq
```

**Linux (CentOS/RHEL):**
```bash
sudo yum install jq
```

## Usage

### 1. Deploy the Test State Machine (Optional)

First, deploy the test state machine using CloudFormation:

```bash
aws cloudformation create-stack \
  --stack-name long-running-test-statemachine \
  --template-body file://test-statemachine.yaml \
  --capabilities CAPABILITY_IAM
```

Wait for the stack to complete:

```bash
aws cloudformation wait stack-create-complete \
  --stack-name long-running-test-statemachine
```

Get the state machine ARN:

```bash
aws cloudformation describe-stacks \
  --stack-name long-running-test-statemachine \
  --query 'Stacks[0].Outputs[?OutputKey==`StateMachineArn`].OutputValue' \
  --output text
```

### 2. Start Test Executions

To test the cancellation script, start some test executions with different sleep times:

```bash
# Get the state machine ARN
STATE_MACHINE_ARN=$(aws cloudformation describe-stacks \
  --stack-name long-running-test-statemachine \
  --query 'Stacks[0].Outputs[?OutputKey==`StateMachineArn`].OutputValue' \
  --output text)

# Start a few test executions (these will run for 1 hour each)
for i in {1..5}; do
  aws stepfunctions start-execution \
    --state-machine-arn $STATE_MACHINE_ARN \
    --input '{"SleepTime": 3600}' \
    --name "test-execution-$i-$(date +%s)"
done

# Start some shorter executions (5 minutes) for testing
for i in {1..3}; do
  aws stepfunctions start-execution \
    --state-machine-arn $STATE_MACHINE_ARN \
    --input '{"SleepTime": 300}' \
    --name "short-test-execution-$i-$(date +%s)"
done
```

### 3. Run the Cancellation Script

#### Dry Run (Preview Mode)

To see which executions would be stopped without actually stopping them:

```bash
./cancel-old-executions.sh \
  --state-machine-arn $STATE_MACHINE_ARN \
  --batch-size 50 \
  --age-seconds 300 \
  --sleep-seconds 2
```

This will:
- Check the state machine at `$STATE_MACHINE_ARN`
- Process 50 executions per page
- Find executions older than 300 seconds (5 minutes)
- Wait 2 seconds between pages
- **NOT** actually stop any executions (dry run)

#### Clean Mode (Actually Stop Executions)

To actually stop old executions:

```bash
./cancel-old-executions.sh \
  --state-machine-arn $STATE_MACHINE_ARN \
  --batch-size 50 \
  --age-seconds 300 \
  --sleep-seconds 2 \
  --clean
```

This will perform the same checks but actually stop the executions.

## Script Parameters

```
./cancel-old-executions.sh --state-machine-arn <arn> --batch-size <num> --age-seconds <num> --sleep-seconds <num> [--clean]
```

| Parameter | Required | Description |
|-----------|----------|-------------|
| --state-machine-arn | Yes | The ARN of the Step Functions state machine |
| --batch-size | Yes | Number of executions to retrieve per page (recommend 50-100) |
| --age-seconds | Yes | Age threshold in seconds - executions older than this will be targeted |
| --sleep-seconds | Yes | Number of seconds to sleep between processing pages (helps avoid throttling) |
| --clean | No | Flag to actually stop executions (without this, it's a dry run) |

## Examples

### Example 1: Find executions older than 5 minutes (dry run - good for testing)

```bash
./cancel-old-executions.sh \
  --state-machine-arn arn:aws:states:us-east-1:123456789012:stateMachine:MyStateMachine \
  --batch-size 50 \
  --age-seconds 300 \
  --sleep-seconds 2
```

### Example 2: Stop executions older than 24 hours

```bash
./cancel-old-executions.sh \
  --state-machine-arn arn:aws:states:us-east-1:123456789012:stateMachine:MyStateMachine \
  --batch-size 50 \
  --age-seconds 86400 \
  --sleep-seconds 2 \
  --clean
```

### Example 3: Stop executions older than 12 hours with larger batch size

```bash
./cancel-old-executions.sh \
  --state-machine-arn arn:aws:states:us-east-1:123456789012:stateMachine:MyStateMachine \
  --batch-size 100 \
  --age-seconds 43200 \
  --sleep-seconds 3 \
  --clean
```

**Common age-seconds values:**
- 300 = 5 minutes (good for testing)
- 3600 = 1 hour
- 43200 = 12 hours
- 86400 = 24 hours
- 172800 = 48 hours

## Script Features

- ✅ **Pagination Support**: Handles thousands of executions by paging through results
- ✅ **Throttling Prevention**: Configurable sleep between pages to avoid API rate limits
- ✅ **Dry Run Mode**: Preview what would be stopped without making changes
- ✅ **Detailed Logging**: Color-coded output with execution details and progress
- ✅ **Error Handling**: Validates input parameters and handles API errors gracefully
- ✅ **Summary Report**: Shows total executions checked, found, and stopped

## Test State Machine Details

The CloudFormation template creates:

- **State Machine**: `LongRunningTestStateMachine`
  - Accepts JSON input with `SleepTime` parameter (in seconds)
  - Uses a Wait state to simulate long-running execution
  - Logs to CloudWatch for monitoring
  
- **IAM Role**: Execution role with necessary permissions
- **CloudWatch Log Group**: `/aws/stepfunctions/LongRunningTestStateMachine`

### State Machine Flow

```
LogStart (Pass) 
    ↓
WaitForSleepTime (Wait for SleepTime seconds)
    ↓
LogCompletion (Pass)
    ↓
Success (Succeed)
```

### Input Format

```json
{
  "SleepTime": 3600
}
```

Where `SleepTime` is the number of seconds the execution will remain in RUNNING status.

## Cleanup

To remove the test state machine:

```bash
aws cloudformation delete-stack \
  --stack-name long-running-test-statemachine
```

## Troubleshooting

### "jq: command not found"

Install jq using your package manager (see Prerequisites section).

### "Error calling AWS API"

- Verify your AWS credentials are configured: `aws sts get-caller-identity`
- Check that you have the necessary IAM permissions
- Ensure the state machine ARN is correct

### "Could not parse start date"

This is typically a non-fatal warning. The script will skip executions it cannot parse and continue processing others.

### Throttling Errors

If you encounter throttling errors:
- Increase the `sleep-seconds` parameter (e.g., from 2 to 5)
- Decrease the `batch-size` parameter (e.g., from 100 to 50)

## Best Practices

1. **Always run a dry run first** to verify which executions will be stopped
2. **Start with conservative age thresholds** (e.g., 86400+ seconds / 24+ hours) to avoid stopping recent executions
3. **For testing, use shorter age thresholds** (e.g., 300 seconds / 5 minutes) to see the script in action
4. **Use appropriate batch sizes** - larger batches are faster but may cause throttling
5. **Monitor the output** during execution to catch any issues
6. **Set appropriate sleep intervals** - 2-3 seconds is usually sufficient for most use cases

## License

This is free and unencumbered software released into the public domain.
