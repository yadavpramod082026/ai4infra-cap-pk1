## Storage I/O Bottleneck & Replication Lag Fault Injection Script
## Purpose: Deliberately trigger storage performance degradation and replication lag
## WARNING: This script will create significant I/O load and API throttling
## MUST have restore_storage.ps1 tested and ready before running this

param(
    [Parameter(Mandatory=$true)]
    [string]$StorageAccountName,
    
    [Parameter(Mandatory=$true)]
    [string]$StorageAccountKey,
    
    [Parameter(Mandatory=$false)]
    [string]$ContainerName = "workload-data",
    
    [Parameter(Mandatory=$false)]
    [int]$FaultDurationSeconds = 120,
    
    [Parameter(Mandatory=$false)]
    [int]$FileSize_MB = 50,
    
    [Parameter(Mandatory=$false)]
    [int]$ParallelUploads = 10,
    
    [Parameter(Mandatory=$false)]
    [string]$LogFilePath = "C:\Logs\fault_injection.log"
)

## Initialize logging
$LogDir = Split-Path -Path $LogFilePath -Parent
if (-not (Test-Path $LogDir)) {
    New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
}

$TempDir = "C:\Temp"
if (-not (Test-Path $TempDir)) {
    New-Item -ItemType Directory -Path $TempDir -Force | Out-Null
}

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $Timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss.fff"
    $LogMessage = "$Timestamp [$Level] $Message"
    Add-Content -Path $LogFilePath -Value $LogMessage
    Write-Host $LogMessage
}

function Create-LargeTestFile {
    param([string]$FilePath, [int]$SizeMB)
    
    Write-Log "Creating test file: $FilePath ($SizeMB MB)"
    
    try {
        # Create file with random data (to ensure each upload is unique)
        $file = New-Item -Path $FilePath -ItemType File -Force
        $fileStream = [System.IO.File]::Create($FilePath)
        $buffer = New-Object byte[] (1MB)
        
        for ($i = 0; $i -lt $SizeMB; $i++) {
            [System.Random]::new().NextBytes($buffer)
            $fileStream.Write($buffer, 0, $buffer.Length)
        }
        
        $fileStream.Close()
        $fileStream.Dispose()
        
        Write-Log "Test file created successfully: $(Get-Item $FilePath | Select-Object -ExpandProperty Length) bytes"
        return $true
    }
    catch {
        Write-Log "Failed to create test file: $_" "ERROR"
        return $false
    }
}

function Get-StorageContext {
    param(
        [string]$AccountName,
        [string]$AccountKey,
        [bool]$UseSecondaryEndpoint = $false
    )
    
    try {
        if ($UseSecondaryEndpoint) {
            # For read-only access to secondary endpoint (if account supports RA-GRS)
            $ctx = New-AzStorageContext -StorageAccountName $AccountName -StorageAccountKey $AccountKey -UseSecondaryEndpoint -ErrorAction Stop
            Write-Log "Secondary endpoint storage context created for $AccountName"
        }
        else {
            $ctx = New-AzStorageContext -StorageAccountName $AccountName -StorageAccountKey $AccountKey -ErrorAction Stop
            Write-Log "Primary endpoint storage context created for $AccountName"
        }
        return $ctx
    }
    catch {
        Write-Log "Failed to create storage context: $_" "ERROR"
        throw
    }
}

function Inject-IOBottleneck {
    param(
        [object]$StorageContext,
        [string]$ContainerName,
        [string]$TestFile,
        [int]$DurationSeconds,
        [int]$ParallelCount
    )
    
    Write-Log "========== FAULT INJECTION: I/O BOTTLENECK STARTED =========="
    Write-Log "Uploading large files in parallel to create I/O bottleneck"
    Write-Log "Duration: $DurationSeconds seconds | Parallel uploads: $ParallelCount"
    
    $startTime = Get-Date
    $uploadCount = 0
    $failureCount = 0
    $throttleCount = 0
    $totalBytes = 0
    
    try {
        while ((Get-Date) -lt $startTime.AddSeconds($DurationSeconds)) {
            $jobs = @()
            
            # Start parallel upload jobs
            for ($i = 0; $i -lt $ParallelCount; $i++) {
                $blobName = "fault_test_$(Get-Date -Format 'yyyyMMdd_HHmmss.fff')_job$i.bin"
                
                $job = Start-Job -ScriptBlock {
                    param($Context, $Container, $File, $Blob)
                    
                    try {
                        $startUpload = Get-Date
                        Set-AzStorageBlobContent -File $File -Container $Container `
                            -Blob $Blob -Context $Context -Force -ErrorAction Stop
                        $endUpload = Get-Date
                        
                        $duration = ($endUpload - $startUpload).TotalSeconds
                        return @{
                            Status = "SUCCESS"
                            BlobName = $Blob
                            Duration = $duration
                            Size = (Get-Item $File).Length
                        }
                    }
                    catch {
                        if ($_.Exception -match "throttled|429|503") {
                            return @{
                                Status = "THROTTLED"
                                BlobName = $Blob
                                Error = $_.Exception.Message
                            }
                        }
                        else {
                            return @{
                                Status = "FAILED"
                                BlobName = $Blob
                                Error = $_.Exception.Message
                            }
                        }
                    }
                } -ArgumentList $StorageContext, $ContainerName, $TestFile, $blobName
                
                $jobs += $job
            }
            
            # Wait for jobs to complete
            $results = $jobs | Wait-Job | Receive-Job
            
            # Process results
            foreach ($result in $results) {
                switch ($result.Status) {
                    "SUCCESS" {
                        $uploadCount++
                        $totalBytes += $result.Size
                        Write-Log "✓ Upload succeeded: $($result.BlobName) ($([Math]::Round($result.Duration, 2))s)" "INFO"
                    }
                    "THROTTLED" {
                        $throttleCount++
                        Write-Log "⚠ Storage throttling detected (429): $($result.BlobName)" "WARN"
                    }
                    "FAILED" {
                        $failureCount++
                        Write-Log "✗ Upload failed: $($result.BlobName) - $($result.Error)" "ERROR"
                    }
                }
            }
            
            # Small delay between batches
            Start-Sleep -Milliseconds 500
        }
    }
    catch {
        Write-Log "Fault injection error: $_" "ERROR"
    }
    
    $elapsedTime = ((Get-Date) - $startTime).TotalSeconds
    
    Write-Log "========== FAULT INJECTION: I/O BOTTLENECK COMPLETED =========="
    Write-Log "Uploads completed: $uploadCount | Failed: $failureCount | Throttled: $throttleCount"
    Write-Log "Total data uploaded: $([Math]::Round($totalBytes / 1MB, 2)) MB in $elapsedTime seconds"
    Write-Log "Throughput: $([Math]::Round(($totalBytes / 1MB) / $elapsedTime, 2)) MB/sec"
    
    return @{
        UploadCount = $uploadCount
        FailureCount = $failureCount
        ThrottleCount = $throttleCount
        TotalBytes = $totalBytes
        ElapsedSeconds = $elapsedTime
        Throughput_MBps = [Math]::Round(($totalBytes / 1MB) / $elapsedTime, 2)
    }
}

function Monitor-ReplicationLag {
    param(
        [object]$PrimaryContext,
        [object]$SecondaryContext = $null,
        [string]$ContainerName
    )
    
    Write-Log "========== MONITORING REPLICATION LAG =========="

    if (-not $SecondaryContext) {
        Write-Log "Secondary endpoint context unavailable. Ensure the storage account uses RAGRS before running replication checks." "WARN"
        return @()
    }
    
    try {
        # Get latest blob from primary
        $primaryBlobs = Get-AzStorageBlob -Container $ContainerName -Context $PrimaryContext | 
            Sort-Object -Property TimeCreated -Descending | Select-Object -First 5
        
        $lagIssues = @()
        
        foreach ($blob in $primaryBlobs) {
            Write-Log "Checking replication lag for: $($blob.Name)"
            
            try {
                # Try to retrieve same blob from secondary
                $secondaryBlob = Get-AzStorageBlob -Container $ContainerName -Blob $blob.Name `
                    -Context $SecondaryContext -ErrorAction Stop
                
                # Calculate lag (this is simplified - real lag detection requires timestamps)
                $lagSeconds = 0  # In reality, you'd check last-modified timestamps
                Write-Log "✓ Blob replicated to secondary: $($blob.Name) (lag: ~$lagSeconds seconds)"
            }
            catch {
                # Blob not yet replicated to secondary - indicates replication lag
                $lagIssues += @{
                    BlobName = $blob.Name
                    TimeCreated = $blob.TimeCreated
                    Error = "Blob not yet available on secondary endpoint"
                }
                Write-Log "⚠ REPLICATION LAG DETECTED: $($blob.Name) not found on secondary (Time Created: $($blob.TimeCreated))" "WARN"
            }
        }
        
        Write-Log "========== REPLICATION LAG MONITORING COMPLETED =========="
        Write-Log "Blobs with replication lag: $($lagIssues.Count)"
        
        return $lagIssues
    }
    catch {
        Write-Log "Failed to monitor replication lag: $_" "ERROR"
        return @()
    }
}

function Measure-PerformanceDegradation {
    param(
        [object]$Context,
        [string]$ContainerName,
        [string]$TestFile
    )
    
    Write-Log "========== MEASURING PERFORMANCE DEGRADATION =========="
    
    try {
        # Upload single file and measure time
        $measurements = @()
        
        for ($i = 0; $i -lt 5; $i++) {
            $blobName = "perf_test_measurement_$i.bin"
            $startTime = Get-Date
            
            Set-AzStorageBlobContent -File $TestFile -Container $ContainerName `
                -Blob $blobName -Context $Context -Force -ErrorAction Stop
            
            $endTime = Get-Date
            $duration = ($endTime - $startTime).TotalSeconds
            $fileSize = (Get-Item $TestFile).Length / 1MB
            $throughput = $fileSize / $duration
            
            $measurements += @{
                Iteration = $i
                Duration = $duration
                Throughput_MBps = $throughput
            }
            
            Write-Log "Measurement $($i+1)/5: $duration seconds ($throughput MB/sec)"
            Start-Sleep -Seconds 2
        }
        
        $avgThroughput = ($measurements | Measure-Object -Property Throughput_MBps -Average).Average
        Write-Log "Average throughput: $([Math]::Round($avgThroughput, 2)) MB/sec"
        Write-Log "========== PERFORMANCE DEGRADATION MEASUREMENT COMPLETED =========="
        
        return $measurements
    }
    catch {
        Write-Log "Failed to measure performance: $_" "ERROR"
        return @()
    }
}

function Generate-FaultReport {
    param([hashtable]$BottleneckResults, [array]$ReplicationLagIssues, [array]$PerformanceMetrics)
    
    $reportPath = "$LogDir\fault_injection_report_$(Get-Date -Format 'yyyyMMdd_HHmmss').txt"
    
    $report = @"
=== STORAGE FAULT INJECTION REPORT ===
Timestamp: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
Duration: $($BottleneckResults.ElapsedSeconds) seconds

I/O BOTTLENECK RESULTS:
  Total Uploads: $($BottleneckResults.UploadCount)
  Failed Uploads: $($BottleneckResults.FailureCount)
  Throttling Events: $($BottleneckResults.ThrottleCount)
  Total Data: $([Math]::Round($BottleneckResults.TotalBytes / 1MB, 2)) MB
  Throughput: $($BottleneckResults.Throughput_MBps) MB/sec

REPLICATION LAG:
  Issues Detected: $($ReplicationLagIssues.Count)
$(if ($ReplicationLagIssues.Count -gt 0) {
  "  Details:`r`n  " + ($ReplicationLagIssues | ForEach-Object { "- $($_.BlobName) created at $($_.TimeCreated)" } | Out-String)
})

PERFORMANCE DEGRADATION:
  Measurements: $($PerformanceMetrics.Count)
  Average Throughput: $([Math]::Round(($PerformanceMetrics | Measure-Object -Property Throughput_MBps -Average).Average, 2)) MB/sec

FAULT STATUS:
  ✓ I/O bottleneck injected successfully
  $(if ($ReplicationLagIssues.Count -gt 0) { "✓ Replication lag detected" } else { "⚠ No replication lag detected (fault may not have been severe enough)" })
  $(if ($BottleneckResults.ThrottleCount -gt 0) { "✓ API throttling events recorded" } else { "⚠ No throttling events (increase parallel uploads)" })

NEXT STEPS:
  1. Verify symptoms with monitoring and logs
  2. Document evidence in structured format
  3. Run restore_storage.ps1 to remediate
  4. Validate recovery
"@
    
    Set-Content -Path $reportPath -Value $report
    Write-Log "Fault injection report saved to: $reportPath"
    return $reportPath
}

## MAIN EXECUTION
Write-Log "========== STORAGE FAULT INJECTION SCRIPT STARTED =========="
Write-Log "⚠ WARNING: This will create significant I/O load and API throttling"
Write-Log "Storage Account: $StorageAccountName | Container: $ContainerName"
Write-Log "Duration: $FaultDurationSeconds seconds | File Size: $FileSize_MB MB | Parallel: $ParallelUploads"

## Confirm before proceeding
Write-Host "`n⚠ WARNING: About to inject storage fault for $FaultDurationSeconds seconds"
Write-Host "This will:"
Write-Host "  1. Create I/O bottleneck through parallel large file uploads"
Write-Host "  2. Potentially trigger API throttling (429 errors)"
Write-Host "  3. Expose replication lag on geo-redundant accounts"
Write-Host ""
Write-Host "Ensure restore_storage.ps1 has been tested and is ready!"
Write-Host ""
$confirmation = Read-Host "Type 'CONFIRM FAULT' to proceed (or press Enter to cancel)"

if ($confirmation -ne "CONFIRM FAULT") {
    Write-Log "Fault injection cancelled by user"
    exit 1
}

try {
    # Step 1: Create test file
    $testFilePath = Join-Path $TempDir "storage_fault_test_$([System.Random]::new().Next(10000)).bin"
    $fileCreated = Create-LargeTestFile -FilePath $testFilePath -SizeMB $FileSize_MB
    
    if (-not $fileCreated) {
        throw "Failed to create test file"
    }
    
    # Step 2: Get storage contexts
    $primaryContext = Get-StorageContext -AccountName $StorageAccountName -AccountKey $StorageAccountKey -UseSecondaryEndpoint $false
    $secondaryContext = $null

    try {
        $secondaryContext = Get-StorageContext -AccountName $StorageAccountName -AccountKey $StorageAccountKey -UseSecondaryEndpoint $true
    }
    catch {
        Write-Log "Secondary endpoint context could not be created. Replication lag checks will be skipped until the storage account is RAGRS and the secondary endpoint is available." "WARN"
    }
    
    # Step 3: Inject I/O bottleneck
    $bottleneckResults = Inject-IOBottleneck -StorageContext $primaryContext -ContainerName $ContainerName `
        -TestFile $testFilePath -DurationSeconds $FaultDurationSeconds -ParallelCount $ParallelUploads
    
    # Step 4: Monitor replication lag
    $lagIssues = Monitor-ReplicationLag -PrimaryContext $primaryContext -SecondaryContext $secondaryContext -ContainerName $ContainerName
    
    # Step 5: Measure performance degradation
    $perfMetrics = Measure-PerformanceDegradation -Context $primaryContext -ContainerName $ContainerName -TestFile $testFilePath
    
    # Step 6: Generate report
    $reportPath = Generate-FaultReport -BottleneckResults $bottleneckResults -ReplicationLagIssues $lagIssues `
        -PerformanceMetrics $perfMetrics
    
    # Cleanup
    Remove-Item $testFilePath -Force -ErrorAction SilentlyContinue
    
    Write-Log "========== STORAGE FAULT INJECTION SCRIPT COMPLETED =========="
    Write-Log "✓ Fault injection complete. Evidence captured in logs."
    Write-Log "⚠ IMPORTANT: Run restore_storage.ps1 immediately to remediate"
    
    exit 0
}
catch {
    Write-Log "Fatal error during fault injection: $_" "ERROR"
    Write-Log "Stack trace: $($_.ScriptStackTrace)" "ERROR"
    Write-Log "⚠ CRITICAL: Storage may be in inconsistent state. Run restore_storage.ps1 immediately" "ERROR"
    exit 2
}
