# Testing StoreKit 2

Complete guide for testing in-app purchases across all environments.

## Testing Environments

| Environment | Use Case | Certificates | Renewal Speed |
|-------------|----------|--------------|---------------|
| **Xcode StoreKit** | Local development | Self-signed | Configurable |
| **Sandbox** | End-to-end testing | Apple Sandbox | Accelerated |
| **Production** | Live app | Apple Production | Real time |

## Xcode StoreKit Testing

Best for rapid local development.

### Setup

1. **Create Configuration File**: File > New > File > StoreKit Configuration File
2. **Sync with App Store Connect** (optional) or add products manually
3. **Enable in Scheme**: Edit Scheme > Run > Options > StoreKit Configuration

### Key Features

- Test without network connectivity
- Configurable renewal timing
- Simulate various scenarios via Debug menu
- No Sandbox account required

### Debug Menu Options

In Xcode: **Debug > StoreKit > Manage Transactions**

- Approve/decline pending transactions
- Trigger subscription renewals
- Simulate billing failures
- Process refunds
- Test grace periods

### Limitations

- Uses **self-signed certificates** (not Apple Root CA)
- Backend certificate validation will fail
- Different from Sandbox/Production behavior

### Backend Testing with Xcode StoreKit

Your backend needs environment-aware verification:

```python
def verify_transaction(jws: str, is_testing: bool = False):
    if is_testing:
        # Skip root CA validation for Xcode testing
        verifier = SignedDataVerifier(
            root_certificates=[],  # Allow any root
            enable_online_checks=False
        )
    else:
        verifier = SignedDataVerifier(
            root_certificates=[apple_root_cert],
            enable_online_checks=True
        )
```

## Sandbox Testing

For end-to-end testing with real App Store Connect products.

### Setup

1. **Create Sandbox Tester** in App Store Connect:
   - Users and Access > Testers (Sandbox)
   - Use unique email (can be fake, e.g., test1@example.com)

2. **Sign In on Device**:
   - iOS 18+: Settings > Developer > Sandbox Apple Account
   - Earlier: Sign in when prompted during purchase

### Accelerated Renewals

| Actual Duration | Sandbox Duration |
|----------------|------------------|
| 1 week | 3 minutes |
| 1 month | 5 minutes |
| 2 months | 10 minutes |
| 3 months | 15 minutes |
| 6 months | 30 minutes |
| 1 year | 1 hour |

Subscriptions renew up to 6 times in Sandbox, then expire.

### Sandbox vs Xcode StoreKit

| Feature | Xcode StoreKit | Sandbox |
|---------|---------------|---------|
| Network required | No | Yes |
| Apple account | No | Sandbox tester |
| Certificates | Self-signed | Apple Sandbox |
| Timing | Configurable | Fixed accelerated |
| Backend validation | Requires bypass | Works normally |

### Testing Subscription Scenarios in Sandbox

1. **Initial Purchase**: Buy subscription, verify access granted
2. **Renewal**: Wait for accelerated renewal, verify continued access
3. **Cancellation**: Turn off auto-renew in Settings, verify expiration
4. **Upgrade/Downgrade**: Change plans, verify correct behavior
5. **Billing Failure**: Apple handles this automatically in Sandbox

### Clearing Sandbox Data

To reset a tester's purchase history:
- App Store Connect > Users and Access > Testers
- Select tester > Clear Purchase History

## Production Testing

Use TestFlight for final validation.

### TestFlight + Sandbox

- TestFlight builds use **Sandbox environment**
- Real users with Sandbox accounts
- Full end-to-end testing before release

### Production Considerations

- Real money transactions
- Full certificate validation
- Real renewal timing
- No accelerated testing

## Testing Checklist

### App-Side

- [ ] Products load correctly
- [ ] Purchase flow completes
- [ ] Transaction listener receives renewals
- [ ] Restore purchases works
- [ ] Pending (Ask to Buy) handled correctly
- [ ] Revocations remove access
- [ ] Offline entitlements work

### Backend

- [ ] JWS verification succeeds (Sandbox certificates)
- [ ] Environment checking works
- [ ] originalTransactionID stored correctly
- [ ] Duplicate transactions handled idempotently
- [ ] Server notifications received
- [ ] Refunds revoke access

### Subscription Scenarios

- [ ] Initial purchase grants access
- [ ] Renewals maintain access
- [ ] Cancellation expires correctly
- [ ] Upgrade/downgrade works
- [ ] Grace period behavior correct
- [ ] Billing retry behavior correct

## Common Testing Issues

### "Cannot Connect to iTunes Store"

- Check network connectivity
- Verify Sandbox account is valid
- Sign out and back in
- Check device date/time settings

### Purchase Stuck in Pending

- In Xcode: Debug > StoreKit > Manage Transactions > Approve
- In Sandbox: Check for Ask to Buy restrictions

### Transactions Not Appearing

- Verify `Transaction.updates` listener is active
- Check that transactions aren't already finished
- Restart app to trigger redelivery

### Backend Validation Failing

- For Xcode: Bypass certificate validation in test mode
- For Sandbox: Ensure using Sandbox API endpoint
- Check environment field matches

## Debug Logging

Add logging to track transaction flow:

```swift
extension StoreManager {
    private func logTransaction(_ transaction: Transaction) {
        #if DEBUG
        print("""
        Transaction:
        - ID: \(transaction.id)
        - Original ID: \(transaction.originalID)
        - Product: \(transaction.productID)
        - Revoked: \(transaction.revocationDate != nil)
        - Environment: \(transaction.environment.rawValue)
        """)
        #endif
    }
}
```

## Useful Commands

### Check Transaction Environment

```swift
let transaction = try checkVerified(result)
print("Environment: \(transaction.environment)")  // .production, .sandbox, .xcode
```

### Force Sync with App Store

```swift
try await AppStore.sync()
```

### List All Unfinished Transactions

```swift
for await result in Transaction.unfinished {
    let transaction = try checkVerified(result)
    print("Unfinished: \(transaction.id)")
}
```
