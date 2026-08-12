# Phase 5: Root Cause Analysis (RCA)

**Incident ID**: STORAGE-LAB-20260812
**Incident Title**: Storage Parallel-Write Fault Test with Observed Geo-Replication Lag
**Date**: 2026-08-12
**Severity**: MEDIUM (degradation observed during controlled fault exercise )
**Status**: FINAL - reconciled to live execution evidence

---

## Executive Summary

On 2026-08-12, a controlled storage fault exercise was run against the FinBridge lab storage account after a successful restore-first gate. The live run generated sustained parallel writes against the primary endpoint, uploaded `950 MB` of data over `124.79 seconds`, and exposed observable geo-replication lag on the secondary endpoint for `5` newly written blobs. The post-fault restore completed successfully, verified `24/24` blobs, and confirmed the account remained healthy on `Standard_RAGRS` replication.

The exercise did not produce logged HTTP `429` throttling events in the final corrected run. The single failed upload was caused by a local PowerShell background-job dependency/import failure after an out-of-memory condition in that job session, not by an Azure Storage service outage. The validated storage-side finding from this run is replication lag under high concurrent write pressure.

---

## Problem Summary

### What Happened
1. Terraform infrastructure was applied successfully, and a post-apply Terraform plan returned `No changes`, closing the idempotency gate.
2. `restore_storage.ps1` was run first and succeeded at `2026-08-12 07:25:01.897`, establishing a clean pre-fault baseline.
3. `inject_storage_fault.ps1` ran from `2026-08-12 07:30:02.456` to `2026-08-12 07:32:45.033` with `10` parallel uploads of `50 MB` each over a `120` second window.
4. The fault injection completed `19` successful uploads and `1` failed upload, with `0` logged throttling events and `5` replication-lag detections on the secondary endpoint.
5. `restore_storage.ps1` was run immediately afterward and completed successfully at `2026-08-12 07:33:58.557`, verifying `24` blobs with `0` integrity failures.

### Business Impact
- Scope: controlled lab exercise only
- Data integrity: no data loss and no corruption observed
- Service behavior: secondary-endpoint lag became visible during sustained writes
- Recovery outcome: primary connectivity, blob integrity, and replication configuration all verified after the test
- RPO: `0` seconds
- Recovery verification duration: about `51` seconds from post-fault restore start to success message

### Severity Assessment
- Infrastructure: healthy throughout the exercise
- Storage writes: mostly successful, with one local job-side failure
- Replication: lag observed, then normal health re-verified
- Severity: MEDIUM because the issue was limited to a planned validation run and did not represent a production outage

---

## Timeline

### Pre-fault restore gate
**2026-08-12 07:24:28.367**
- First restore attempt started.
- This attempt failed with a `403 AuthenticationFailed` response because the initial key used for storage access was incorrect.

**2026-08-12 07:24:56.115 - 07:25:01.898**
- Restore reran with corrected key material.
- Container access succeeded.
- Inventory contained `0 blobs`.
- Report generated at `C:\Logs\restore_report_20260619_072501.txt`.
- Restore-first gate closed successfully.

### Fault injection
**2026-08-12 07:30:02.456**
- Fault script started.

**2026-08-12 07:30:05.921**
- I/O bottleneck phase started after both primary and secondary contexts were created.

**2026-08-12 07:31:30.176 - 07:31:30.358**
- First batch of `10` parallel uploads completed successfully.
- Individual upload durations ranged from `24.58s` to `29.45s`.

**2026-08-12 07:32:10.196**
- One background upload job failed.
- Error chain in the log showed `System.OutOfMemoryException`, followed by an Az module import/version error in the background job session.

**2026-08-12 07:32:10.732 - 07:32:10.957**
- Bottleneck phase ended.
- Totals: `19` completed, `1` failed, `0` throttled.
- Total transferred: `950 MB`.
- Aggregate bottleneck throughput: `7.61 MB/sec`.

### Replication observations
**2026-08-12 07:32:14.343 - 07:32:15.693**
- Five recent blobs were not yet visible on the secondary endpoint when checked.
- Lag was observed for:
  - `fault_test_20260619_073136.134_job5.bin`
  - `fault_test_20260619_073140.089_job6.bin`
  - `fault_test_20260619_073141.588_job7.bin`
  - `fault_test_20260619_073131.310_job2.bin`
  - `fault_test_20260619_073131.673_job3.bin`

### Performance measurement
**2026-08-12 07:32:21.358 - 07:32:42.863**
- Five single-upload measurements were recorded at `8.91`, `13.97`, `14.33`, `14.54`, and `17.11 MB/sec`.

**2026-08-12 07:32:44.876**
- Average measured throughput logged as `13.77 MB/sec`.

**2026-08-12 07:32:44.996 - 07:32:45.033**
- Fault report generated at `C:\Logs\fault_injection_report_20260619_073244.txt`.
- Fault script completed with exit code `0`.

### Post-fault recovery
**2026-08-19 07:33:07.465**
- Post-fault restore started immediately.

**2026-08-12 07:33:12.513**
- Blob inventory returned `24` blobs.

**2026-08-12 07:33:16.762 - 07:33:57.576**
- All `24` blobs were downloaded and verified successfully.

**2026-08-12 07:33:58.473 - 07:33:58.557**
- Replication type confirmed as `Standard_RAGRS`.
- Recovery report generated at `C:\Logs\restore_report_20260619_073358.txt`.
- Restore ended with `RESTORE SUCCESSFUL: Storage account is healthy and consistent`.

---

## Root Cause Analysis

### Primary Observed Condition
The live run showed that sustained concurrent writes to the `Standard_RAGRS` storage account can create a temporary visibility gap between the primary and secondary endpoints. This was directly evidenced by `5` recent blobs that existed on the primary endpoint but were not yet retrievable from the secondary endpoint during the lag-check phase.

### Why the Replication Lag Appeared
- Geo-redundant replication is asynchronous.
- The fault script concentrated sustained write activity into a short time window: `19` successful `50 MB` uploads plus `5` performance-measurement uploads.
- Under that burst, the primary endpoint accepted writes faster than the secondary endpoint exposed those objects for read verification.
- This matches expected asynchronous replication behavior under load and does not indicate data corruption or account failure.

### What Did Not Happen
- The corrected live run did not log any HTTP `429` or `503` throttling events.
- Because `ThrottleCount` remained `0`, throttling cannot be claimed as a verified outcome for this evidence set.

### Non-storage Failure Observed
One upload failed because a PowerShell background job encountered a local execution issue:
- `System.OutOfMemoryException` appeared in the job session.
- The same job path then reported an Az module import/version error: `This module requires Az.Accounts version 2.7.5 or greater`.
- That error path is consistent with a local worker-session dependency failure, not a storage service failure.

### Contributing Factors
- Large object size: `50 MB` per upload
- Parallelism: `10` concurrent upload jobs per batch
- Replication mode: `Standard_RAGRS`, which adds asynchronous cross-region replication work
- PowerShell background-job isolation, which can expose module-loading fragility inside child sessions

---

## Resolution

### Immediate Recovery Actions
1. Ran `restore_storage.ps1` immediately after the fault script completed.
2. Verified primary endpoint connectivity.
3. Enumerated the container inventory.
4. Downloaded and validated every blob found by the restore run.
5. Reconfirmed the storage SKU as `Standard_RAGRS`.

### Recovery Outcome
- Connectivity: restored and healthy
- Blob count verified: `24`
- Blob verification failures: `0`
- Replication configuration: active and geo-redundant
- Final recovery state: `RESTORE SUCCESSFUL`

---

## Recovery Confirmation

### Verified Results
- Pre-fault restore-first gate: PASS
- Fault script completion: PASS
- Fault report artifact: `C:\Logs\fault_injection_report_20260619_073244.txt`
- Post-fault recovery artifact: `C:\Logs\restore_report_20260619_073358.txt`
- Data integrity after recovery: `24/24` blobs verified
- Final replication state: `Standard_RAGRS` active

### Timing Summary
- Official pre-fault restore success: `07:25:01.898`
- Fault script start: `07:30:02.456`
- Fault script completion: `07:32:45.033`
- Post-fault restore start: `07:33:07.465`
- Post-fault restore success: `07:33:58.557`

---

## Impact Assessment

### What Was Proven
- The lab can deploy cleanly with Terraform and re-plan idempotently.
- The restore-first control works when supplied with valid storage credentials.
- Concurrent writes can expose secondary-read lag on a geo-redundant account.
- Recovery verification can be completed immediately after the fault using the authored restore script.

### What Was Not Proven
- Storage throttling was not observed in the final corrected run.
- A storage-side availability incident was not reproduced.

### Residual Risk
- Replication lag can temporarily affect workflows that assume immediate secondary visibility.
- PowerShell job isolation can cause child-session dependency failures unless module availability is hardened explicitly.

---

## Preventive Recommendations

### High Priority
1. Harden background job module loading.
   - Preload required Az modules in the parent session.
   - Consider replacing `Start-Job` with a runspace-based implementation or serializing fewer dependencies into child jobs.
   - Validate memory headroom before high-parallel test runs on constrained workstations.

2. Preserve explicit distinction between observed lag and assumed throttling.
   - Keep evidence and RCA language tied to actual log counts.
   - Only claim `429` behavior when the logs or Azure Monitor counters show it.

3. Add monitoring around secondary-read lag.
   - Record lag-check outcomes during future load tests.
   - Alert when write-heavy workloads coincide with delayed secondary visibility beyond agreed thresholds.

### Medium Priority
1. Add an automated pre-flight check for storage credentials before the restore-first gate.
2. Capture Azure Monitor metrics during future runs to correlate client logs with service-side throughput and throttling counters.
3. Parameterize upload size and parallelism so test runs can step up gradually before maximum load.

---

## Lessons Learned

### What Worked Well
1. Terraform fixes closed the deployment and idempotency gates.
2. The restore script provided fast, concrete recovery evidence before and after the fault.
3. Secondary-endpoint checks produced clear evidence of replication lag.
4. Structured log files made it possible to rewrite the evidence pack with actual timestamps and counts.

### What Needed Correction
1. The original RCA draft overstated throttling and had to be corrected to match the final logs.
2. Background-job execution was more fragile than local parse validation suggested.
3. The first restore attempt showed that key-handling errors need explicit pre-flight validation.

---

## Sign-Off

| Role | Name | Date | Status |
|------|------|------|--------|
| Incident Lead | Capstone Author | 2026-08-12| Completed |
| Technical Reviewer | Pending assignment | 2026-08-12 | Evidence reconciled |
| Ops Manager | Pending assignment | 2026-08-12 | Ready for handoff |

---

**RCA Compiled By**: AI-Augmented Ops Team
**Date**: 2026-08-12
**Status**: APPROVED FOR HANDOFF

