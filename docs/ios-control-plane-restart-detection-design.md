# iOS Control Plane Restart Detection - Design Document

## Problem Statement

The iOS client fails to detect when the control plane restarts, leading to:
- App remains in `.connected` state even though control plane is down
- Connection failures only discovered when attempting to send messages
- HTTP/2 stream closure from server graceful shutdown is not being detected

## Current Implementation Analysis

### Architecture
- **Transport**: NIOHTTPClient for HTTP/2 streaming (Connect protocol)
- **Keepalive**: 30-second idle keepalive sending `.sync` messages
- **Activity Tracking**: Updates `lastActivityAt` on send/receive
- **Stream Handling**: `startReceiving()` processes stream results including `.complete()` case

### Key Code Paths

**Connection Lifecycle** (`ConnectService.swift`):
```swift
private func startReceiving(stream: ...) {
    receiveTask = Task {
        for await result in stream.results() {
            switch result {
            case .headers: // Headers received
            case .message: // Server message
            case .complete(let code, let error, _):
                // This SHOULD trigger on stream closure
                await handleDisconnection()
            }
        }
    }
}
```

**Keepalive** (lines 1243-1258):
```swift
private func startKeepAlive() {
    keepAliveTask = Task {
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 30_000_000_000) // 30s
            if idleTime >= keepAliveIdleThreshold {
                self.send(.sync)
            }
        }
    }
}
```

**Send with Error Handling** (lines 1220-1241):
```swift
func send(_ message: ClientMessage) {
    guard connectionState == .connected || connectionState == .connecting, let stream = stream else {
        return
    }
    Task {
        do {
            try await stream.send(protoMessage)
        } catch {
            // If send fails, trigger reconnection
            await handleDisconnection()
        }
    }
}
```

### Root Cause Analysis

When control plane restarts:
1. **Server graceful shutdown**: Closes HTTP/2 connections with GOAWAY frame
2. **Expected behavior**: `stream.results()` should receive `.complete()` and trigger `handleDisconnection()`
3. **Actual behavior**: Stream closure is NOT being detected by the receive loop
4. **Detection delay**: Only discovered when next message send fails (could be 30+ seconds if idle)

**Possible NIO/HTTP2 Issues**:
- NIO HTTP/2 stream lifecycle may not immediately propagate connection closure to Swift async stream
- GOAWAY frame handling might be delayed or buffered
- iOS network extension (Tailscale) may interfere with immediate TCP closure detection
- Stream may be in "zombie" state where it appears connected but can't send/receive

## Design Approaches

---

## Approach 1: Active Health Checking with Dedicated Ping/Pong

### Overview
Replace idle-only keepalive with mandatory bidirectional health checking using request-response pairs.

### Mechanism
1. **Periodic Ping**: Send `.sync` message every 15 seconds (down from 30s)
2. **Response Timeout**: Expect `.syncResponse` within 5 seconds
3. **Health State Machine**:
   - `healthy`: Received pong in last health check cycle
   - `degraded`: Missed one pong but still connected
   - `dead`: Missed two consecutive pongs → trigger reconnection

### Implementation Changes

**File**: `ConnectService.swift`

**Add health check state**:
```swift
private enum HealthState {
    case healthy
    case degraded(missedCount: Int)
    
    var isDead: Bool {
        if case .degraded(let count) = self, count >= 2 { return true }
        return false
    }
}

private var healthState: HealthState = .healthy
private var lastPongReceivedAt: Date?
private let healthCheckInterval: UInt64 = 15_000_000_000 // 15s
private let healthCheckTimeout: TimeInterval = 5.0
```

**Replace `startKeepAlive()` with `startHealthCheck()`**:
```swift
private func startHealthCheck() {
    keepAliveTask?.cancel()
    keepAliveTask = Task { [weak self] in
        while !Task.isCancelled {
            guard let self else { return }
            guard self.connectionState == .connected else { continue }
            
            // Send health check ping
            let pingSentAt = Date()
            self.send(.sync)
            
            // Wait for response or timeout
            try? await Task.sleep(nanoseconds: self.healthCheckTimeout * 1_000_000_000)
            
            // Check if pong was received
            if let lastPong = self.lastPongReceivedAt, lastPong >= pingSentAt {
                // Pong received - mark healthy
                self.healthState = .healthy
            } else {
                // No pong - increment missed count
                switch self.healthState {
                case .healthy:
                    logger.warning("Health check missed (1/2)")
                    self.healthState = .degraded(missedCount: 1)
                case .degraded(let count):
                    let newCount = count + 1
                    logger.warning("Health check missed (\(newCount)/2)")
                    self.healthState = .degraded(missedCount: newCount)
                }
                
                // If dead, trigger reconnection
                if self.healthState.isDead {
                    logger.error("Health checks failed - connection dead")
                    await self.handleDisconnection(reason: .serverError("Health check failed"))
                }
            }
            
            // Wait until next interval (only if not dead)
            guard !self.healthState.isDead else { break }
            try? await Task.sleep(nanoseconds: self.healthCheckInterval)
        }
    }
}
```

**Update message handler to track pongs**:
```swift
case .syncResponse(let msg):
    self.lastPongReceivedAt = Date()
    self.healthState = .healthy  // Reset on successful pong
    return .syncResponse(sessions: ..., serverTime: ...)
```

### Trade-offs

**Pros**:
- ✅ **Reliable detection**: Guaranteed detection within 15-20 seconds (15s interval + 5s timeout)
- ✅ **Bidirectional verification**: Tests both send and receive paths
- ✅ **Graceful degradation**: Can detect partial failures before full disconnection
- ✅ **No false positives**: Two missed pongs reduces spurious reconnections

**Cons**:
- ⚠️ **Battery usage**: Sending pings every 15s increases background network activity
- ⚠️ **Server load**: More frequent requests (2x current keepalive frequency)
- ⚠️ **Complexity**: State machine adds code complexity
- ⚠️ **Detection latency**: Still up to 35 seconds worst-case (2 × 15s + 5s)

**Battery Impact Mitigation**:
- Use background mode: Only ping every 15s when app is active/foreground
- When backgrounded: Extend to 60s interval (acceptable since app is suspended anyway)
- Respect iOS Low Power Mode: Extend intervals further

---

## Approach 2: Stream Lifecycle Monitoring with Error Detection

### Overview
Fix the root cause by ensuring stream closure is properly detected, plus add redundant send failure detection.

### Mechanism
1. **Enhanced Stream Monitoring**: Better detection of stream completion/errors
2. **Send Error Recovery**: Immediate reconnection on any send failure
3. **Stream Validation**: Periodic lightweight validation that stream is readable

### Implementation Changes

**File**: `ConnectService.swift`

**Add stream validation task**:
```swift
private var streamValidationTask: Task<Void, Never>?
private let streamValidationInterval: UInt64 = 10_000_000_000 // 10s

private func startStreamValidation() {
    streamValidationTask?.cancel()
    streamValidationTask = Task { [weak self] in
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: self?.streamValidationInterval ?? 10_000_000_000)
            
            guard let self else { return }
            guard self.connectionState == .connected else { continue }
            
            // Validate that receiveTask is still running
            if let receiveTask = self.receiveTask, receiveTask.isCancelled {
                logger.error("Receive task cancelled unexpectedly - reconnecting")
                await self.handleDisconnection(reason: .serverError("Stream closed"))
            }
        }
    }
}
```

**Enhanced receive loop with better error detection**:
```swift
private func startReceiving(stream: ..., onValidation: ...) {
    receiveTask = Task { [weak self] in
        var validationCallback = onValidation
        var hasValidated = false
        
        do {
            for await result in stream.results() {
                guard let self, !Task.isCancelled else { break }
                
                switch result {
                case .headers:
                    print("[Connect] Received headers")
                    self.recordActivity()
                    if !hasValidated {
                        hasValidated = true
                        validationCallback?(true)
                        validationCallback = nil
                    }
                    
                case .message(let protoMessage):
                    self.recordActivity()
                    if !hasValidated {
                        hasValidated = true
                        validationCallback?(true)
                        validationCallback = nil
                    }
                    if let serverMessage = self.convertProtoMessage(protoMessage) {
                        self._messagesContinuation?.yield(serverMessage)
                    }
                    
                case .complete(let code, let error, _):
                    print("[Connect] Stream completed: code=\(code), error=\(String(describing: error))")
                    if !hasValidated {
                        hasValidated = true
                        validationCallback?(false)
                        validationCallback = nil
                    }
                    // CRITICAL: Ensure we trigger reconnection
                    await self.handleDisconnection(reason: .serverError("Stream closed: \(code)"))
                    break  // Exit loop explicitly
                }
            }
            
            // If we exit the loop without .complete, connection is broken
            logger.error("Stream results loop ended without .complete - connection lost")
            if !hasValidated {
                validationCallback?(false)
            }
            await self?.handleDisconnection(reason: .serverError("Stream ended unexpectedly"))
            
        } catch {
            // Catch any errors from the stream iteration itself
            logger.error("Stream iteration error: \(error)")
            if !hasValidated {
                validationCallback?(false)
            }
            await self?.handleDisconnection(reason: .serverError("Stream error: \(error.localizedDescription)"))
        }
    }
}
```

**Make send failure handling synchronous and immediate**:
```swift
func send(_ message: ClientMessage) {
    guard connectionState == .connected || connectionState == .connecting, let stream = stream else {
        logger.warning("send: dropped message (not connected)")
        return
    }

    recordActivity()
    let protoMessage = convertToProtoMessage(message)
    
    Task { @MainActor in  // Ensure reconnection happens on MainActor
        do {
            try await stream.send(protoMessage)
        } catch {
            logger.error("Failed to send message: \(error.localizedDescription)")
            // Immediate reconnection on send failure
            guard !Task.isCancelled else { return }
            guard self.connectionState.isConnected else { return }  // Avoid duplicate reconnects
            
            logger.error("Send failed with connected state - triggering immediate reconnection")
            await self.handleDisconnection(reason: .serverError("Send failed"))
        }
    }
}
```

**Update startReceiving call in performConnect**:
```swift
// After stream creation
startReceiving(stream: currentStream, onValidation: { success in ... })
startStreamValidation()  // NEW: Add stream validation task
```

### Trade-offs

**Pros**:
- ✅ **Root cause fix**: Addresses the actual problem (stream closure detection)
- ✅ **Fast detection on send**: Immediate reconnection if user tries to send
- ✅ **Low overhead**: Only validates stream state every 10s (no network traffic)
- ✅ **Minimal battery impact**: No extra network requests
- ✅ **Defense in depth**: Multiple detection mechanisms (stream close + send fail + validation)

**Cons**:
- ⚠️ **Still relies on stream.results()**: If NIO bug prevents `.complete()`, validation task only checks every 10s
- ⚠️ **Reactive on idle**: If connection dies and no messages sent, detection still takes 10s
- ⚠️ **Doesn't test receive path**: Stream validation only checks if task is alive, not if data can flow

**Detection Latency**:
- Best case: Immediate (send failure)
- Stream closure: Immediate (when NIO delivers `.complete()`)
- Idle connection death: Up to 10 seconds (validation interval)

---

## Approach 3: Hybrid - Health Checks + Enhanced Stream Detection

### Overview
Combine the reliability of active health checking with proper stream lifecycle handling.

### Mechanism
1. **Moderate health checks**: Ping every 20s with 8s timeout (less aggressive than Approach 1)
2. **Enhanced stream detection**: Proper `.complete()` handling and error catching
3. **Immediate send failure recovery**: Instant reconnection on send errors
4. **Single missed pong triggers reconnection**: No tolerance for missed responses

### Implementation Changes

**File**: `ConnectService.swift`

**Health check with single-strike failure**:
```swift
private var lastHealthCheckSentAt: Date?
private var lastHealthCheckReceivedAt: Date?
private let healthCheckInterval: UInt64 = 20_000_000_000 // 20s
private let healthCheckTimeout: TimeInterval = 8.0

private func startHealthCheck() {
    keepAliveTask?.cancel()
    keepAliveTask = Task { [weak self] in
        while !Task.isCancelled {
            guard let self else { return }
            guard self.connectionState == .connected else {
                try? await Task.sleep(nanoseconds: 1_000_000_000)  // Wait 1s if not connected
                continue
            }
            
            // Send health check
            let checkSentAt = Date()
            self.lastHealthCheckSentAt = checkSentAt
            self.send(.sync)
            
            // Wait for timeout
            try? await Task.sleep(nanoseconds: UInt64(self.healthCheckTimeout * 1_000_000_000))
            
            // Check if response received
            if let lastReceived = self.lastHealthCheckReceivedAt,
               lastReceived >= checkSentAt {
                // Health check passed
                logger.debug("Health check passed")
            } else {
                // Health check failed - immediate reconnection
                logger.error("Health check timeout - no syncResponse received")
                await self.handleDisconnection(reason: .serverError("Health check timeout"))
                break  // Exit health check loop
            }
            
            // Wait for next interval
            try? await Task.sleep(nanoseconds: self.healthCheckInterval)
        }
    }
}
```

**Track health check responses**:
```swift
case .syncResponse(let msg):
    self.lastHealthCheckReceivedAt = Date()
    return .syncResponse(sessions: msg.sessions.map { ... }, serverTime: msg.serverTime.date)
```

**Enhanced receive loop** (same as Approach 2 - proper error handling):
```swift
private func startReceiving(stream: ..., onValidation: ...) {
    receiveTask = Task { [weak self] in
        // ... (same as Approach 2 - with do-catch and explicit break on .complete)
    }
}
```

**Adjust intervals for background** (battery optimization):
```swift
// In prepareForBackground():
private let backgroundHealthCheckInterval: UInt64 = 60_000_000_000 // 60s when backgrounded

// Use isForeground flag to adjust interval:
let interval = self.isForeground ? self.healthCheckInterval : self.backgroundHealthCheckInterval
```

### Trade-offs

**Pros**:
- ✅ **Reliable detection**: Multiple mechanisms ensure detection within 28 seconds worst-case
- ✅ **Defense in depth**: Health check + stream monitoring + send failure detection
- ✅ **Reasonable battery usage**: 20s interval is gentler than 15s
- ✅ **Simple logic**: Single missed health check = reconnect (no state machine)
- ✅ **Fast when active**: Immediate detection if user sends message

**Cons**:
- ⚠️ **Still some battery impact**: Regular pings every 20s when foreground
- ⚠️ **False positives possible**: Single timeout could be transient network blip (mitigated by auto-reconnect)
- ⚠️ **Added complexity**: More code than either approach alone

**Detection Latency**:
- Active send: Immediate (0s)
- Stream closure: Immediate when NIO delivers `.complete()`
- Idle health check failure: 20s interval + 8s timeout = 28s worst-case

**Battery Optimization**:
- Foreground: 20s interval
- Background: 60s interval (app is suspended, no user interaction)
- Low Power Mode: Could extend to 120s

---

## Recommended Approach: **Approach 3 (Hybrid)**

### Rationale

**Why Approach 3 is Best**:

1. **Defense in Depth**: Multiple detection mechanisms ensure we catch control plane restarts regardless of which path fails:
   - Stream closure detection fixes the root cause if NIO works properly
   - Health checks provide guaranteed detection even if stream lifecycle is broken
   - Send failure detection catches issues immediately when user is active

2. **Balanced Trade-offs**:
   - 20-second health check interval is reasonable (less aggressive than 15s)
   - 28-second worst-case detection is acceptable for most use cases
   - Battery impact is moderate and can be tuned (60s background, respect Low Power Mode)

3. **Simplicity**: Single missed health check triggers reconnection (no complex state machine like Approach 1)

4. **Real-world Reliability**: 
   - Approach 1 alone might still miss stream closure issues
   - Approach 2 alone relies too heavily on NIO behavior being perfect
   - Hybrid catches problems regardless of where they originate

5. **User Experience**:
   - When active: Near-instant detection via send failure
   - When idle: Detection within 28s is acceptable (user isn't waiting)
   - Auto-reconnect means seamless recovery in most cases

### Implementation Priority

**Phase 1 - Critical Fixes** (Do first):
1. Fix receive loop error handling (from Approach 2)
2. Make send failure trigger immediate reconnection (from Approach 2)
3. Add explicit stream validation after loop exit

**Phase 2 - Add Health Checks** (Do second):
1. Replace idle keepalive with bidirectional health checks
2. Track `.syncResponse` timestamps
3. Implement single-strike timeout → reconnection

**Phase 3 - Polish** (Do later):
1. Add battery optimizations (background intervals, Low Power Mode)
2. Add telemetry/metrics for detection latency
3. Tune intervals based on real-world data

### Alternative: Start with Approach 2 Only

If battery life is a critical concern (e.g., targeting heavy background usage):
- **Start with Approach 2**: Fix stream detection properly
- **Monitor in production**: Track how often detection fails vs succeeds
- **Add health checks selectively**: Only if Approach 2 proves insufficient

This allows data-driven decision making about whether health checks are necessary.

---

## Implementation Checklist

### Must-Have Changes (Approach 2 baseline)
- [ ] Wrap `stream.results()` loop in `do-catch` to catch iteration errors
- [ ] Explicitly `break` on `.complete()` case
- [ ] Add fallback disconnection if loop exits without `.complete()`
- [ ] Make send failures trigger immediate reconnection
- [ ] Ensure `handleDisconnection()` is only called once per disconnect event

### Health Check Addition (Approach 3)
- [ ] Add health check state variables (`lastHealthCheckSentAt`, `lastHealthCheckReceivedAt`)
- [ ] Replace `startKeepAlive()` with `startHealthCheck()` 
- [ ] Update `.syncResponse` handling to record timestamp
- [ ] Implement 20s interval + 8s timeout + single-strike reconnection
- [ ] Add foreground/background interval switching

### Testing Strategy
- [ ] Unit test: Health check timeout triggers reconnection
- [ ] Unit test: Send failure triggers immediate reconnection  
- [ ] Integration test: Kill control-plane pod, verify detection within 30s
- [ ] Integration test: Control-plane graceful restart, verify immediate detection
- [ ] Battery test: Measure battery drain with 20s health checks vs baseline

### Monitoring/Telemetry (Nice to have)
- [ ] Log health check round-trip times
- [ ] Track detection method (stream close vs health timeout vs send failure)
- [ ] Measure time-to-detection for different scenarios
- [ ] Alert if detection consistently takes >30s

---

## Alternative Considerations

### Why Not Use TCP Keepalive?
- **Tailscale network extension**: TCP keepalive might not work properly through VPN
- **iOS power management**: OS may delay or suppress TCP keepalive probes
- **No visibility**: Can't control intervals or detect failures at application level
- **Verdict**: Not reliable enough for this use case

### Why Not Use gRPC HTTP/2 PING Frames?
- **Connect protocol**: We're using Connect, not pure gRPC
- **NIO abstraction**: `BidirectionalAsyncStreamInterface` doesn't expose HTTP/2 PING
- **Verdict**: Would be ideal but not available with current stack

### Why Not WebSocket Instead of HTTP/2?
- **Different protocol**: Would require server-side changes
- **No clear benefit**: WebSocket has same detection issues (need application-level pings)
- **Verdict**: Not worth the migration effort

---

## Success Criteria

**Primary Goal**: Detect control plane restart within 30 seconds in all scenarios

**Metrics**:
- ✅ Detection time < 30s for graceful shutdown: 95th percentile
- ✅ Detection time < 10s when user sends message: 99th percentile  
- ✅ No false positive disconnections: < 1% of health checks
- ✅ Battery impact: < 5% increase in background drain vs current implementation

**Test Scenarios**:
1. Control plane pod restart (graceful shutdown)
2. Control plane deployment rollout
3. Network switch (WiFi → Cellular → WiFi)
4. iOS app background → foreground transition
5. Idle connection for 5+ minutes

