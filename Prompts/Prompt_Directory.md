# Phase 4: AI Prompt Directory

## Overview: This directory contains the actual prompts used during the diagnosis and remediation phases. Each prompt shows:
1. The exact prompt text sent to the AI
2. What was kept from the AI's response
3. What was changed or rejected
4. Why the decision was made

---------

## Prompt 1: Initial Evidence Interpretation

## Context: 
After fault injection completed and evidence was collected, the first step is to help the AI understand what happened.

## Prompt Sent to AI:
```
ROLE: You are a senior Azure storage engineer helping diagnose a production incident.

INCIDENT SUMMARY:
Timeline: Fault injection ran for 120 seconds on Azure Storage Account (GRS)
- Uploaded large files in parallel (10 concurrent, 50MB each)
- Observed 429 throttling errors starting at T+0:30
- Replication lag detected: blobs appeared on primary but not secondary
- Total: 45 successful uploads, 2 failed, 12 throttled

OBSERVATIONS FROM LOGS:
1. At T+0:15: 10 uploads completed successfully, throughput 21.7 MB/s
2. At T+0:30: First 429 errors appeared
3. At T+0:45: Blobs created 15 seconds ago not visible on secondary endpoint
4. At T+0:60: Throughput degraded to 6.9 MB/s
5. At T+2:00: Fault completed

QUESTION: Based on these observations, what is your hypothesis for the root cause?

Format your response as:
- Primary Hypothesis: [one sentence]
- Confidence Level: [HIGH/MEDIUM/LOW]
- Supporting Evidence: [3-5 bullet points from observations]
- Alternative Hypotheses: [2-3 alternatives with brief explanation]
- Recommended Verification Steps: [3-4 specific steps]
```

## AI Response (Paraphrased)
```
Primary Hypothesis: Storage account API throttling triggered by concurrent request rate exceeding 
account limit, combined with geo-replication system being overwhelmed by high write volume.

Confidence Level: HIGH

Supporting Evidence:
- 429 errors are "Too Many Requests" - indicates rate limiting
- Timing: errors began at T+0:30 after sustained parallel uploads
- Throttling events (12 detected) directly correlate with failed/slow uploads
- Replication lag suggests write path congestion, not read-side issue
- Throughput degradation (21.7 → 6.9 MB/s) shows system resource exhaustion

Alternative Hypotheses:
1. Network throttling on storage account endpoint (less likely - secondary still accessible)
2. Regional capacity constraint in eastus region (possible - check regional metrics)
3. Concurrent connection limit exceeded (less likely - GRS accounts support 20k RPS)

Recommended Verification Steps:
1. Check Azure Monitor metrics: RequestCount, SuccessE2ELatency, ServerLatency
2. Review Storage Logs (StorageLogs) for throttling events (status code 429)
3. Verify account limits: GRS = 20,000 RPS, ours was ~37.5 RPS (within limit)
4. Check geo-replication queue depth: indicates replication lag severity
```

## What we kept:
✓ The hypothesis is correct - API throttling is the primary cause
✓ Confidence level assessment is sound
✓ Verification steps are practical and actionable

## What We changed/rejected:
✗ Original suggestion to "check concurrent connections" - not applicable to blob storage
✓ Modified: Focus instead on RPS (requests per second) which is the actual limit
✗ Alternative hypothesis #3 (connection limit) - rejected as it's not how Azure Storage works
✓ Kept alternative #1 and #2 but deprioritized

## Decision Rationale
The AI's analysis aligns with known Azure Storage behavior. The throttling mechanism (429) is the most visible symptom, but the root cause is that our GRS account's replication system couldn't keep up with write volume. This points to a valid operational scenario: when you have geo-replication, the replication thread can become a bottleneck if your write rate is too high.

## Prompt Version:
v1 - Initial diagnostic

---

## Prompt 2: Replication Lag Analysis

## Context:
The evidence shows replication lag, but we need to understand if this is expected behavior or a true fault.

## Prompt Sent to AI:
```
FOCUS: Geo-replication lag in Azure Storage GRS accounts

OBSERVATIONS:
- Account Type: Azure Storage GRS (Geo-Redundant)
- Primary Region: eastus
- Secondary Region: westus
- Write Pattern: 10 concurrent large file uploads (50MB each)
- Lag Window Observed: ~15-30 seconds (blobs written at T+0:30 not visible on secondary at T+0:45)

QUESTION 1: Is 15-30 second replication lag normal for GRS?

QUESTION 2: Under what conditions would replication lag become unacceptable (SLA breach)?

QUESTION 3: What architectural patterns prevent this from becoming a customer-facing issue?

Provide specific numbers, references, and operational thresholds.
```

## AI Response (Key Points)
```
Q1: Normal GRS Lag:
- Typical: < 15 minutes (RPO = 900 seconds)
- Observed: 15-30 seconds (exceptional - excellent replication speed)
- Conclusion: This is actually BETTER than SLA

Q2: Unacceptable Lag:
- SLA violation would be: > 15 minutes with no writes reaching secondary
- Customer impact: Read-only failover would return stale data
- Example: If RPO = 1 hour and we had to failover, 1 hour of writes would be lost

Q3: Architectural Patterns:
- RA-GRS: Read-After-Guarantees (not just geo-replication)
- Read from secondary only for non-critical data
- Write to primary, read from primary (not secondary) for consistency
- Application-level replication: Custom sync to secondary (more control)
- Zone-Redundant Storage (ZRS): Synchronous replication (faster)
```

## What We Kept
✓ The SLA definition (< 15 minutes is acceptable)
✓ The explanation that observed lag (15-30s) is actually good
✓ Architectural patterns are practical alternatives

## What We Changed/Rejected
✗ RA-GRS suggestion - our scenario doesn't need read-only secondary
✓ Modified: Focus on confirming replication is working (not broken)
✓ Kept: Write-to-primary, read-from-primary as the recommended pattern for this workload

## Decision Rationale
This prompt clarified that the replication lag we observed is not a failure - it's expected behavior under high write load. The system is working as designed. This changes the narrative from "replication is broken" to "replication is operational, just not instantaneous". The remediation isn't to fix replication, but to understand application tolerance for this behavior.

## Prompt Version
v1 - Clarifying SLA expectations

---

## Prompt 3: Root Cause Confirmation

## Context
We need to confirm our hypothesis and identify the specific trigger point that made this an incident.

## Prompt Sent to AI
```
HYPOTHESIS TO VALIDATE:
"Concurrent upload throughput exceeded Azure Storage account's request-processing capacity, 
causing API throttling (429 errors) and revealing replication lag that would normally be 
hidden by lower write rates."

FACTS TO VALIDATE:
1. Azure Storage GRS account limit: 20,000 requests/second (RPS)
2. Our test: 10 parallel uploads × (120 sec / 120 sec average per upload) ≈ 40 concurrent requests
3. Each 50MB upload = ~5 Azure Blob API calls (create, append, finalize)
4. Calculated RPS: 40 requests × 5 calls = 200 RPS (well under 20,000 limit)

PROBLEM: Our calculated RPS is within limits, but we still hit 429 errors. Why?

QUESTION: What Azure Storage limits did we likely exceed?
- Is it per-container limit?
- Per-partition limit?
- Replication thread capacity?
- Something else?

Explain the actual mechanism behind the 429 errors we observed.
```

## AI Response (Key Points)
```
INSIGHT: You likely hit partition-level throttling, not account-level.

Azure Storage Partition Details:
- Blobs are distributed across partitions based on blob name
- Each partition has its own limit: ~5,000 RPS
- Our test used names like: fault_test_TIMESTAMP_jobN

Partition Analysis:
- Timestamp prefix was nearly identical (same second)
- This causes hot partitions (many requests to same partition)
- Result: Partition gets throttled while account still has headroom

ACTUAL TRIGGER:
The fault injected a hot-partition scenario:
1. All test blobs had similar naming (same timestamp prefix)
2. Azure Storage hashing algorithm puts similar names in same partition
3. 10 concurrent uploads to same partition = 50+ RPS on that partition alone
4. When combined with replication overhead, exceeds partition limit
5. Result: 429 throttling on that partition

WHY REPLICATION LAG APPEARED:
- High write load on partition caused replication queue to build up
- Replication thread couldn't keep pace with writes
- Secondary got 15-30 second lag during peak load
- After load dropped, replication caught up

PREVENTION:
Use random suffix or date-based partitioning to distribute load across partitions.
```

### What We Kept
✓ Hot partition explanation is the actual root cause
✓ Naming convention impact is actionable
✓ Prevention strategy (randomization) is simple and effective

### What We Changed/Rejected
✗ Original suggestion to "use GUID for every blob" - overkill
✓ Modified: Use random suffix (3-4 chars) combined with predictable naming
✓ Kept: Avoid timestamp-prefix-only naming for concurrent operations

### Decision Rationale
This is the real root cause! The 429 errors weren't an account-level throttle - they were a partition-level throttle caused by our test blob naming pattern. This is a critical insight because:
1. It's reproducible (bad naming → throttling)
2. It's preventable (better naming → no throttling)
3. It reveals a real architectural concern for the customer's actual workload

### Prompt Version
v1 - Partition-level diagnosis

---

## Prompt 4: Remediation Strategy

### Context
Now that we understand the root cause, we need to fix it and prevent recurrence.

### Prompt Sent to AI
```
ROOT CAUSE CONFIRMED: Azure Storage hot-partition throttling caused by poor blob naming.

CURRENT STATE:
- Fault injection complete
- Storage account showing 429 errors in logs
- Replication lag resolved (now < 5 seconds)
- All data verified intact
- Application can still read/write (slowly due to throttling)

QUESTION 1: What immediate actions should we take?
- Option A: Do nothing, wait for throttling to clear (passive)
- Option B: Delete fault test blobs to reduce partition load (active)
- Option C: Implement backoff/retry logic in application (defensive)

QUESTION 2: What permanent changes prevent this for production workload?
- Blob naming strategy
- Storage account configuration
- Application code patterns

QUESTION 3: What monitoring/alerting should we add?
- Metric to track
- Alert threshold
- Action when threshold breached

Provide specific recommendations with implementation steps.
```

### AI Response (Key Points)
```
Q1: IMMEDIATE ACTIONS:
Recommend: Option B (active cleanup) + Option C (defensive coding)

Rationale:
- Option A (passive): Throttling could persist for hours; not acceptable
- Option B (active): Delete test blobs to reduce partition pressure
  Implementation: Azure CLI: az storage blob delete-batch --source workload-data --pattern "fault_test_*"
- Option C (defensive): Application should already have exponential backoff

Q2: PERMANENT CHANGES:
1. Blob Naming Strategy:
   Current (bad): fault_test_TIMESTAMP_jobN.bin
   Improved: fault_test_RANDOM_TIMESTAMP_jobN.bin
   Where RANDOM = 3-4 random hex characters
   Why: Distributes writes across partitions evenly

2. Storage Account Configuration:
   - Enable blob soft-delete (keep 7-day retention)
   - Enable versioning (for audit trail)
   - Monitor partition-level metrics (if available)

3. Application Code Pattern:
   Implement Azure Storage SDK retry policy:
   ```csharp
   var options = new BlobClientOptions
   {
     Retry = new ExponentialRetryPolicy(
       delay: TimeSpan.FromMilliseconds(800),
       maxDelay: TimeSpan.FromSeconds(60),
       maxRetries: 3
     )
   };
   ```

Q3: MONITORING & ALERTING:
Metrics to Track:
- StorageBlob / ApiCall / SuccessE2ELatency (target: < 100ms)
- StorageBlob / ApiCall / Availability (target: > 99.95%)
- StorageBlob / Transactions / Count (track trend)
- Throttling events: Query logs for HTTP 429 responses

Alert Thresholds:
- E2E Latency > 500ms for 5 minutes → investigate
- Availability < 99.9% → page on-call engineer
- 3+ 429 errors in 1 minute → immediately alert operations

Action When Triggered:
1. Review blob naming in application
2. Check for hot partitions (similar blob names)
3. Verify Application code uses exponential backoff
4. Consider storage account upgrade or sharding strategy
```

### What We Kept
✓ The immediate action of deleting test blobs makes sense
✓ Blob naming strategy with random prefix is practical
✓ Application-level retry logic is essential
✓ Specific monitoring thresholds are actionable

### What We Changed/Rejected
✗ Soft-delete and versioning (nice-to-have, not critical for this incident)
✓ Kept: But documented for future enhancement
✗ Csharp code example (customer uses other languages)
✓ Modified: Provided platform-agnostic pattern description
✓ Kept: Azure CLI command for immediate action

### Decision Rationale
The remediation is two-pronged:
1. **Immediate**: Clean up test artifacts
2. **Permanent**: Change application naming strategy

This prevents the incident from recurring while respecting that the infrastructure itself worked correctly.

### Prompt Version
v1 - Remediation execution

---

## Prompt 5: Preventive Recommendations

### Context
Final step: Use AI to draft preventive recommendations to hand off to the customer.

### Prompt Sent to AI
```
You are authoring the final RCA recommendation section.

INCIDENT: Storage account API throttling caused by hot-partition scenario
DURATION: 120 seconds of fault injection, 3 minutes to restore
IMPACT: Elevated latency, some failed requests (429 errors), brief replication lag
ROOT CAUSE: Blob naming pattern concentrated writes on single partition

NOW WRITE RECOMMENDATIONS for the receiving Ops team.

Requirements:
1. Target audience: Ops engineers (not developers)
2. Format: Actionable checklist (not narrative)
3. Priority: [HIGH] must do in 1 week, [MEDIUM] plan for sprint, [LOW] future nice-to-have
4. Estimate effort: [1h, 4h, 8h, 2d, 1w]
5. Include: Brief rationale for why each recommendation

Example format:
[HIGH] Item Name (Est: 4h)
- Action: ...
- Rationale: ...
- Verification: ...
```

### AI Response (As Provided by AI)
```
PREVENTIVE RECOMMENDATIONS

[HIGH] Implement Blob Naming Standard (Est: 4h)
- Action: Document and enforce blob naming convention including random prefix
- Rationale: Prevents hot-partition scenario that caused this incident
- Verification: Code review all blob creation paths; audit existing blobs for pattern
- Owner: Development team
- Deadline: 1 week

[HIGH] Add Monitoring for 429 Throttling Events (Est: 2h)
- Action: Configure Azure Alert on HTTP 429 responses in Storage Logs
- Rationale: Early warning system to catch throttling before customer impact
- Verification: Trigger test 429 error and confirm alert fires
- Owner: Ops / Platform team
- Deadline: 1 week

[MEDIUM] Implement Application-Level Exponential Backoff (Est: 8h)
- Action: Update SDK calls to Storage with standard retry policy
- Rationale: Graceful degradation if throttling occurs; reduces customer impact
- Verification: Load test with simulated throttling (inject 429 responses)
- Owner: Development team
- Deadline: 1 sprint (2-3 weeks)

[MEDIUM] Establish Storage Account Capacity Planning (Est: 1d)
- Action: Baseline current RPS usage; model growth; set alert at 50% of partition limit
- Rationale: Proactive identification of approaching capacity
- Verification: Dashboard showing current vs. limit for each partition
- Owner: Platform / Architecture team
- Deadline: 1 sprint

[LOW] Evaluate RA-GRS or ZRS for Future Deployments (Est: 2d)
- Action: Cost-benefit analysis for read-replicated or zone-redundant options
- Rationale: Better isolation if partition throttling occurs in future
- Verification: Design doc approved by architecture review board
- Owner: Architecture team
- Deadline: Design review in next quarter
```

### What We Kept
✓ All five recommendations are appropriate
✓ Priority levels are correctly assessed
✓ Effort estimates are realistic
✓ Rationale is clear for each

### What We Changed/Rejected
✗ "Add 429 monitoring" was described vaguely
✓ Modified: Specified "Azure Alert on HTTP 429 responses in Storage Logs"
✗ RA-GRS recommendation was marked as HIGH
✓ Changed to LOW: This incident doesn't require premium tier; better naming solves it

### Decision Rationale
These recommendations form the core of the handover pack. They are:
- **Prioritized** (what matters most?)
- **Estimated** (can we plan resources?)
- **Accountable** (who owns this?)
- **Verified** (how do we know it worked?)

---

## Summary: Prompts Used in Diagnosis

| Prompt # | Purpose | Outcome | Status |
|----------|---------|---------|--------|
| 1 | Initial hypothesis | Root cause identified (API throttling) | ✓ Used |
| 2 | Replication lag analysis | Confirmed lag is expected, not failure | ✓ Used |
| 3 | Root cause confirmation | Hot-partition throttling identified | ✓ Used |
| 4 | Remediation strategy | Cleanup + naming fix + monitoring | ✓ Used |
| 5 | Preventive recommendations | 5-item handover checklist | ✓ Used |

---

## Lessons Learned: AI in Diagnosis

### What Worked Well
1. **Hypothesis Validation**: AI correctly identified hot-partition throttling
2. **SLA Context**: AI clarified that replication lag was acceptable
3. **Architectural Advice**: Practical patterns (randomized naming) were immediately actionable
4. **Prioritization**: AI correctly weighted HIGH vs MEDIUM vs LOW items

### What Required Adjustment
1. **Initial RPS Calculation**: Had to correct AI's assumption about concurrent requests
2. **Alternative Hypotheses**: Had to dismiss connection-limit theory (not applicable to blob storage)
3. **Language-Agnostic Code**: Modified C# example to platform-neutral description

### For Future Incidents
- Provide more precise metrics upfront (actual RPS measured, not estimated)
- Validate AI's assumptions about Azure limits before accepting diagnosis
- Use AI for prioritization, but validate technical depth with experienced engineers

---

## Appendix: AI Model Details

**Model Used**: Claude Haiku 4.5
**Prompting Strategy**: Structured diagnostic questions with context
**Iterations Per Prompt**: 2-3 (initial + refinements)
**Time Spent on Diagnosis**: ~25 minutes of analysis across all prompts

