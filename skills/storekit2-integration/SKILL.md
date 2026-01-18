---
name: storekit2-integration
description: Implement StoreKit 2 in-app purchases, subscriptions, consumables, and backend integration. Use when working with IAP, App Store purchases, transaction handling, JWS verification, subscription management, promotional offers, or migrating from StoreKit 1.
---

# StoreKit 2 Integration Guide

Expert guidance for implementing StoreKit 2 with custom backend integration for subscriptions, consumables, and rentals.

## Quick Reference

### Minimum Requirements

- iOS 15+ for StoreKit 2 APIs
- iOS 17+ for SwiftUI views (`ProductView`, `StoreView`, `SubscriptionStoreView`)
- Xcode 14+ (Xcode 15+ for SwiftUI views)

### Product Types

| Type | Restores | Family Sharing | Use Case |
|------|----------|----------------|----------|
| Consumable | No | No | Coins, tips, one-time rentals |
| Non-Consumable | Yes | Opt-in | Permanent unlocks, ad removal |
| Auto-Renewable | Yes | Opt-in | Streaming subscriptions |
| Non-Renewing | Yes | No | Season passes, time-limited access |

### Critical Transaction IDs

| Field | Description | Use For |
|-------|-------------|---------|
| `transaction.id` | Unique per transaction | Logging, deduplication |
| `transaction.originalID` | Stable across renewals | **Database linking** |

**Always use `originalID` for database operations.**

### Essential Store Manager

```swift
import StoreKit

@MainActor
final class StoreManager: ObservableObject {
    @Published private(set) var products: [Product] = []
    @Published private(set) var purchasedProductIDs: Set<String> = []
    private var updateListenerTask: Task<Void, Error>?

    init() {
        // CRITICAL: Start listener at launch
        updateListenerTask = listenForTransactions()
        Task { await updatePurchasedProducts() }
    }

    deinit { updateListenerTask?.cancel() }

    private func listenForTransactions() -> Task<Void, Error> {
        Task {
            for await result in Transaction.updates {
                guard !Task.isCancelled else { break }
                do {
                    let transaction = try checkVerified(result)
                    if transaction.revocationDate != nil {
                        purchasedProductIDs.remove(transaction.productID)
                        await transaction.finish()
                        continue
                    }
                    try await sendJWSToBackend(result.jwsRepresentation)
                    await updatePurchasedProducts()
                    await transaction.finish()  // Only after backend confirms
                } catch { /* Don't finish - will retry */ }
            }
        }
    }

    private func checkVerified<T>(_ result: VerificationResult<T>) throws -> T {
        switch result {
        case .unverified(_, let error): throw error
        case .verified(let safe): return safe
        }
    }
}
```

### Purchase Flow

```swift
func purchase(_ product: Product, userUUID: UUID) async throws -> Transaction? {
    let result = try await product.purchase(options: [.appAccountToken(userUUID)])

    switch result {
    case .success(let verification):
        let transaction = try checkVerified(verification)
        guard transaction.revocationDate == nil else { throw PurchaseError.revoked }
        try await sendJWSToBackend(verification.jwsRepresentation)
        await transaction.finish()  // Only after backend confirms
        return transaction
    case .pending:
        throw PurchaseError.pending  // Will come through Transaction.updates
    case .userCancelled:
        return nil
    @unknown default:
        return nil
    }
}
```

### Backend Verification Checklist

1. Verify JWS signature against certificate chain
2. Validate chain traces to Apple Root CA (G3)
3. Check `environment` field matches expected (Production/Sandbox)
4. Use `originalTransactionID` for database operations
5. Handle idempotency (same transaction may arrive multiple times)
6. Check `revocationDate` before granting access

## Detailed References

- **App Implementation**: See [APP_IMPLEMENTATION.md](APP_IMPLEMENTATION.md) for complete StoreManager, entitlements, restore, and SwiftUI views
- **Backend Integration**: See [BACKEND_INTEGRATION.md](BACKEND_INTEGRATION.md) for JWS verification, App Store Server API, and server notifications
- **Subscription Management**: See [SUBSCRIPTION_MANAGEMENT.md](SUBSCRIPTION_MANAGEMENT.md) for states, billing retry, grace periods, and offers
- **Common Mistakes**: See [COMMON_MISTAKES.md](COMMON_MISTAKES.md) for fatal errors to avoid
- **Testing**: See [TESTING.md](TESTING.md) for Xcode StoreKit, Sandbox, and testing strategies

## Key Best Practices

1. **Always include `appAccountToken`** - Links purchases to your users
2. **Listen to `Transaction.updates` at app launch** - Catches renewals, Family Sharing, Ask to Buy
3. **Finish transactions only after backend confirms** - Prevents lost purchases
4. **Always check `revocationDate`** - Handles refunds and Family Sharing removal
5. **Use `originalID` not `id`** - Stable across subscription renewals
6. **Validate certificate chain on backend** - Prevents forged receipts
7. **Check environment on backend** - Reject Sandbox in Production

## StoreKit 1 vs StoreKit 2

| StoreKit 1 | StoreKit 2 |
|------------|------------|
| `SKPaymentTransactionObserver` | `Transaction.updates` async sequence |
| `SKReceiptRefreshRequest` | `AppStore.sync()` |
| `/verifyReceipt` endpoint | JWS verification or App Store Server API |
| `SKProductsRequest` | `Product.products(for:)` async |
| `SKPaymentQueue.add()` | `product.purchase()` async |

## Official Resources

- [StoreKit Framework](https://developer.apple.com/documentation/storekit)
- [App Store Server API](https://developer.apple.com/documentation/appstoreserverapi)
- [App Store Server Notifications](https://developer.apple.com/documentation/appstoreservernotifications)
- [Meet StoreKit 2 (WWDC21)](https://developer.apple.com/videos/play/wwdc2021/10114/)
- [Apple Server Libraries](https://github.com/apple/app-store-server-library-swift)
