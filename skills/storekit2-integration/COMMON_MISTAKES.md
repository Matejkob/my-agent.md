# Common Fatal Mistakes

Critical errors to avoid when implementing StoreKit 2.

## 1. Not Listening to Transaction.updates

```swift
// WRONG - Missing transaction listener
@MainActor final class StoreManager {
    init() {
        // No listener - will miss renewals, Ask to Buy, Family Sharing
    }
}

// CORRECT
@MainActor final class StoreManager {
    private var updateListenerTask: Task<Void, Error>?

    init() {
        updateListenerTask = Task {
            for await result in Transaction.updates {
                // Process ALL transactions
            }
        }
    }
}
```

**What you'll miss:**
- App Store subscription renewals
- Family Sharing transactions
- Ask to Buy approvals
- Promotional code redemptions
- Subscription changes from Settings

## 2. Finishing Transactions Too Early

```swift
// WRONG - Finishing before backend confirms
case .success(let verification):
    let transaction = try checkVerified(verification)
    await transaction.finish()  // DANGEROUS!
    try await sendToBackend(verification.jwsRepresentation)  // May fail

// CORRECT - Finish only after backend confirms
case .success(let verification):
    let transaction = try checkVerified(verification)
    try await sendToBackend(verification.jwsRepresentation)  // Wait for success
    await transaction.finish()  // Safe to finish now
```

**Result:** Lost purchases. User charged but never gets content.

## 3. Using transactionId Instead of originalID

```swift
// WRONG - Will break on renewal
database.save(userId: user.id, transactionId: transaction.id)

// CORRECT - Stable across all renewals
database.save(userId: user.id, originalTransactionId: transaction.originalID)
```

**Result:** Every renewal creates a "new" subscription instead of extending existing one.

## 4. Ignoring Revocations

```swift
// WRONG - Granting access without checking revocation
let transaction = try checkVerified(result)
grantAccess(for: transaction.productID)

// CORRECT - Always check revocationDate
let transaction = try checkVerified(result)
if transaction.revocationDate != nil {
    revokeAccess(for: transaction.productID)
    return
}
grantAccess(for: transaction.productID)
```

**Result:** Users keep access after refunds or Family Sharing removal.

## 5. Not Checking Environment on Backend

```python
# WRONG - Accepting any receipt
def verify_purchase(jws):
    transaction = decode(jws)
    grant_access(transaction)  # Sandbox receipts work in production!

# CORRECT - Verify environment matches
def verify_purchase(jws, expected_environment="Production"):
    transaction = decode_and_verify(jws)
    if transaction.environment != expected_environment:
        raise SecurityError("Environment mismatch!")
    grant_access(transaction)
```

**Result:** Attackers use Sandbox purchases to get free access in production.

## 6. Not Validating Certificate Chain

```python
# WRONG - Just decoding without signature verification
def verify_purchase(jws):
    payload = base64_decode(jws.split('.')[1])  # Attacker can forge!
    return json.loads(payload)

# CORRECT - Verify signature AND certificate chain
def verify_purchase(jws):
    verifier = SignedDataVerifier(
        root_certificates=[apple_root_ca],  # Must trace to Apple Root CA
        ...
    )
    return verifier.verify_and_decode(jws)  # Cryptographically verified
```

**Result:** Attackers sign fake receipts with their own certificates.

## 7. Double Processing Same Transaction

The same transaction can appear in both `purchase()` result and `Transaction.updates`.

```swift
// Backend should handle duplicate transaction IDs gracefully
func processTransaction(originalId: String, productId: String) {
    if database.exists(originalId) {
        return  // Already processed - idempotent
    }
    database.insert(originalId, productId)
    grantAccess(productId)
}
```

**Result:** Double-crediting or errors on duplicate processing.

## 8. Not Handling Ask to Buy

```swift
// WRONG - Treating pending as failure
case .pending:
    showError("Purchase failed")

// CORRECT - Inform user and wait for Transaction.updates
case .pending:
    showPendingApprovalUI()
    // Transaction will arrive via Transaction.updates when approved
```

**Result:** Poor UX for family accounts; parent approval never processes.

## 9. Not Storing appAccountToken

```swift
// WRONG - No way to link transaction to user
let result = try await product.purchase()

// CORRECT - Link to your user account
let result = try await product.purchase(options: [
    .appAccountToken(userUUID)  // Store this UUID in your user database
])
```

**Result:** Can't determine which user made a purchase from server notifications.

## 10. Treating currentEntitlements as Real-Time

```swift
// WRONG - Assuming this is always current
for await result in Transaction.currentEntitlements {
    // May be stale offline
}

// CORRECT - Use for offline access, verify with backend when online
for await result in Transaction.currentEntitlements {
    // Cache for offline, but backend is source of truth
}
```

**Result:** Stale entitlements when offline; missing recent purchases from other devices.

## 11. Not Finishing Expired Transactions

```swift
// WRONG - Only finishing active subscriptions
if transaction.expirationDate > Date() {
    await transaction.finish()
}

// CORRECT - Finish all processed transactions
await transaction.finish()  // Clears from queue after processing
```

**Result:** Transaction queue grows, causing performance issues.

## 12. Using Task.detached for Transaction Listener

```swift
// WRONG - Loses @MainActor context
Task.detached {
    for await result in Transaction.updates {
        // @MainActor properties can't be accessed
    }
}

// CORRECT - Inherit MainActor context
Task {
    for await result in Transaction.updates {
        // Can safely update @Published properties
    }
}
```

**Result:** Crashes or threading issues when updating UI state.

## Quick Checklist

Before shipping, verify:

- [ ] `Transaction.updates` listener starts at app launch
- [ ] `transaction.finish()` called only after backend confirms
- [ ] `originalID` used for all database operations
- [ ] `revocationDate` checked before granting access
- [ ] Backend validates environment matches (Production/Sandbox)
- [ ] Backend validates certificate chain to Apple Root CA
- [ ] Backend handles duplicate transactions idempotently
- [ ] `.pending` state shows appropriate UI (not error)
- [ ] `appAccountToken` included in purchases
- [ ] Offline behavior handled gracefully
