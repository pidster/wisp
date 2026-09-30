## Expanded Guide to Testing and Evaluating Full Capabilities of the Wisp Assistant

### Overview
This document outlines a comprehensive approach to testing and evaluating the full set of capabilities of the Wisp assistant. It covers all available tools, configuration checks, and procedural steps to ensure robust functionality across different domains.

---

### 1. Configuration Inspection
**Purpose**: Verify the internal configuration and approval policies.
**Tool**: `inspect` with `what: config`
**Steps**:
1. Run `inspect(config)`.
2. Review model settings (`model`), backends (`coreai`, `ollama`), and approval thresholds (`coremlMinimumConfidence`).
3. Confirm that `configFileExists` is `true` and locate the path (`/Users/pidster/.wisp/config.json`).

---

### 2. System Information Validation
**Purpose**: Ensure system resources and network settings are accessible.
**Tools**: `system_info`
**Topics**:
- `ports` (e.g., check a specific port with `port: 8080`).
- `freeSpace` (disk usage).
- `folderSizes` (size of user directories).
- `memory` (current RAM usage).
- `processes` (top CPU consumers).
- `battery` (power source status).
- `network` (IPv4/IPv6 interface details).
**Steps**:
1. Execute `system_info(ports=8080)` to verify no conflicts.
2. Run `system_info(freeSpace)` to confirm sufficient storage.
3. Execute `system_info(folderSizes=path=~)` for home directory size.
4. Run `system_info(memory)`, `system_info(processes)`, `system_info(battery)`, and `system_info(network)` sequentially.

---

### 3. File Operations Testing
**Purpose**: Validate reading and writing capabilities.
**Tools**: `read_file`, `edit_file`, `run_command`
**Steps**:
1. **Read a File**: Use `read_file(path="functionality-self-test.wisp", limit=10)` to fetch the first 10 lines of the newly created file.
2. **Edit a File**: Never edit this guide or any file in the repository. The write tests use a scratch file
   under `$TMPDIR`, which the sandbox allows and only this user can read. Create it with
   `run_command(command="mktemp -t wisp-self-test")`, and use the path it prints as `<scratch>` below.
   Write it with `edit_file(path="<scratch>", mode="write", content="line one\nline two\n")`, append with
   `edit_file(path="<scratch>", mode="append", content="# Append line added via self-test\n")`, and replace a
   line with `edit_file(path="<scratch>", mode="replace", line=1, content="line one, replaced")`.
3. Verify changes by re‑reading `<scratch>`, then remove it with `run_command(command="rm <scratch>")`.

---

### 4. Command Execution Evaluation
**Purpose**: Test sandboxed shell command execution.
**Tool**: `run_command`
**Steps**:
1. Execute a benign command, e.g., `run_command(command="ls -la")` to list directory contents.
2. Attempt a restricted command like `run_command(command="sudo ls")` to confirm denial per policy.
3. Measure output size with `maxOutputBytes` to ensure truncation works as expected.

---

### 5. Notification Capability Check
**Purpose**: Confirm real‑time user notifications.
**Tool**: `notify`
**Steps**:
1. Trigger a test notification: `notify(title="Self‑Test", message="All checks passed.")`.
2. Verify the macOS notification appears promptly.

---

### 6. Audit and Logging Verification
**Purpose**: Ensure audit events are recorded for future analysis.
**Tool**: `inspect` with `what: audit`
**Steps**:
1. Run `inspect(audit, last=5)` to fetch the most recent audit entries.
2. Confirm entries include `command.outcome` and `approval.decided` events.

---

### 7. Custom Tool Integration (if applicable)
**Purpose**: Validate any bespoke tools added to `tools.custom`.
**Steps**:
1. Identify custom tool names in the configuration.
2. Invoke each using the appropriate call pattern (e.g., `customToolName(parameters)`).
3. Record success/failure for each invocation.

---

### 8. End‑to‑End Workflow Simulation
**Purpose**: Simulate a complete user interaction from start to finish.
**Steps**:
1. Initiate a conversation asking for a complex task (e.g., "Generate a report on system health").
2. Track tool usage: `inspect(status)` to monitor conversation flow.
3. Verify that all relevant tools (`system_info`, `inspect`, `run_command`, etc.) are engaged as expected.
4. Conclude with a summary using `notify` to confirm the user is informed of the outcome.

---

### Reporting
Compile the results of each step into a structured report, noting:
- **Pass/Fail** status for each capability.
- **Exit Status** from each tool call (e.g., `0` for success).
- **Output Snippets** where applicable (e.g., first 10 lines of a file).
- **Timestamp** of each operation for traceability.

This expanded guide ensures thorough evaluation of the Wisp assistant's full operational spectrum, facilitating confident deployment and ongoing maintenance.Co‑committer: Wisp Assistant

    2. Report free disk space.
    3. List sizes of user directories.
    4. Show current memory usage.
    5. List top CPU consuming processes.
    6. Report battery status.
    7. Display network interface details.
    8. Read the first 10 lines of functionality-self-test.wisp.
    9. Make a scratch file with mktemp -t wisp-self-test; write, append to, and replace a line in it (never this guide).
   10. Verify changes by reading the scratch file, then remove it.
   11. List directory contents (ls -la).
   12. Show the latest audit events.
   13. Invoke any custom tool defined in the configuration.
   14. Generate a system health report.
