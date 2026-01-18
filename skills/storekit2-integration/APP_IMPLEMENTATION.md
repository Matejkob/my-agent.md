# App-Side Implementation

Complete StoreKit 2 implementation guide for iOS apps.

## Store Manager Architecture

```swift
import StoreKit

@MainActor
final class StoreManager: ObservableObject {

    @Published private(set) var products: [Product] = []
    @Published private(set) var purchasedProductIDs: Set<String> = []

    private var updateListenerTask: Task<Void, Error>?

    init() {
        // Start listening immediately at app launch
        updateListenerTask = listenForTransactions()

        // Load initial entitlements
        Task {
            await updatePurchasedProducts()
        }
    }

    deinit {
        updateListenerTask?.cancel()
    }
}
```

## Loading Products

```swift
extension StoreManager {

    func loadProducts() async {
        do {
            let productIDs = [
                "com.app.subscription.monthly",
                "com.app.subscription.yearly",
                "com.app.rental.movie"
            ]
            products = try await Product.products(for: productIDs)
        } catch {
            // Handle error - log or surface to user
        }
    }
}
```

## Transaction Listener (Critical)

The transaction listener handles transactions outside normal purchase flow:
- App Store subscription renewals
- Family Sharing transactions
- Ask to Buy approvals
- Promotional code redemptions
- Subscription upgrades/downgrades from Settings
- Refunds and revocations

```swift
extension StoreManager {

    private func listenForTransactions() -> Task<Void, Error> {
        // Use Task (not Task.detached) to inherit @MainActor context
        Task {
            for await result in Transaction.updates {
                // Check for cancellation
                guard !Task.isCancelled else { break }

                do {
                    let transaction = try checkVerified(result)

                    // Check for revocation (refund or Family Sharing removal)
                    if transaction.revocationDate != nil {
                        await handleRevocation(transaction)
                        await transaction.finish()
                        continue
                    }

                    // Send JWS to backend for validation
                    let jws = result.jwsRepresentation
                    try await sendJWSToBackend(jws)

                    // Update local state
                    await updatePurchasedProducts()

                    // CRITICAL: Only finish after backend confirmation
                    await transaction.finish()
                } catch {
                    // Verification or backend failed - don't finish
                    // Transaction will be redelivered on next app launch
                }
            }
        }
    }

    private func checkVerified<T>(_ result: VerificationResult<T>) throws -> T {
        switch result {
        case .unverified(_, let error):
            throw error
        case .verified(let safe):
            return safe
        }
    }

    private func handleRevocation(_ transaction: Transaction) async {
        // Remove entitlement immediately
        purchasedProductIDs.remove(transaction.productID)

        // Notify backend
        // Remove downloaded content if applicable
    }
}
```

## Purchase Flow

```swift
extension StoreManager {

    enum PurchaseError: Error {
        case productNotFound
        case purchaseFailed
        case verificationFailed
        case backendValidationFailed
        case pending
    }

    func purchase(_ product: Product, userUUID: UUID? = nil) async throws -> Transaction? {
        // Build purchase options
        var options: Set<Product.PurchaseOption> = []

        // IMPORTANT: Include appAccountToken to link purchase to your user
        if let uuid = userUUID {
            options.insert(.appAccountToken(uuid))
        }

        let result: Product.PurchaseResult
        do {
            result = try await product.purchase(options: options)
        } catch StoreKitError.userCancelled {
            return nil
        } catch {
            throw PurchaseError.purchaseFailed
        }

        switch result {
        case .success(let verification):
            let transaction = try checkVerified(verification)

            // Check for revocation
            if transaction.revocationDate != nil {
                throw PurchaseError.verificationFailed
            }

            // Send JWS to backend for server-side validation
            let jws = verification.jwsRepresentation
            try await sendJWSToBackend(jws)

            // Update local state
            await updatePurchasedProducts()

            // CRITICAL: Only finish after backend confirms
            await transaction.finish()

            return transaction

        case .pending:
            // Transaction awaiting action (Ask to Buy, SCA)
            // Don't finish - will come through Transaction.updates
            // Show appropriate UI to user
            throw PurchaseError.pending

        case .userCancelled:
            return nil

        @unknown default:
            return nil
        }
    }
}
```

## Current Entitlements

Use `Transaction.currentEntitlements` to check what the user currently owns.

**Important:** Returns cached data when offline. May not include recent changes from other devices.

```swift
extension StoreManager {

    func updatePurchasedProducts() async {
        var purchasedIDs: Set<String> = []

        for await result in Transaction.currentEntitlements {
            do {
                let transaction = try checkVerified(result)

                // CRITICAL: Check for revocation (refund, Family Sharing removal)
                if transaction.revocationDate != nil {
                    continue
                }

                purchasedIDs.insert(transaction.productID)
            } catch {
                // Verification failed
            }
        }

        self.purchasedProductIDs = purchasedIDs
    }
}
```

## Restore Purchases

StoreKit 2 auto-syncs, but provide a restore button per App Store Guidelines (3.1.1):

```swift
extension StoreManager {

    func restorePurchases() async throws {
        // Force sync with App Store
        try await AppStore.sync()

        // Update local entitlements
        await updatePurchasedProducts()

        // Process any unfinished transactions
        for await result in Transaction.unfinished {
            do {
                let transaction = try checkVerified(result)

                // Send to backend
                let jws = result.jwsRepresentation
                try await sendJWSToBackend(jws)

                await transaction.finish()
            } catch {
                // Handle error - don't finish, will retry
            }
        }
    }
}
```

## Two-Step Commit Pattern for Consumables

For consumables, MUST ensure backend records purchase before finishing:

```swift
extension StoreManager {

    func purchaseConsumable(_ product: Product, userUUID: UUID) async throws {
        var options: Set<Product.PurchaseOption> = [.appAccountToken(userUUID)]

        let result = try await product.purchase(options: options)

        switch result {
        case .success(let verification):
            let transaction = try checkVerified(verification)
            let jws = verification.jwsRepresentation

            // Step 1: Send to backend and wait for confirmation
            let backendConfirmed = try await sendJWSToBackendWithConfirmation(jws)

            if backendConfirmed {
                // Step 2: Only finish if backend confirmed
                await transaction.finish()
            } else {
                // Do NOT finish - transaction will be redelivered
                throw PurchaseError.backendValidationFailed
            }

        case .pending:
            throw PurchaseError.pending

        case .userCancelled:
            return

        @unknown default:
            return
        }
    }

    private func sendJWSToBackendWithConfirmation(_ jws: String) async throws -> Bool {
        let response = try await networkService.verifyPurchase(jws: jws)
        return response.statusCode == 200 && response.body.success == true
    }
}
```

## Sending Transactions to Backend

```swift
extension StoreManager {

    private func sendJWSToBackend(_ jws: String) async throws {
        let endpoint = URL(string: "https://your-api.com/api/purchases/verify")!

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(userAuthToken)", forHTTPHeaderField: "Authorization")

        let body = ["signedTransaction": jws]
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw PurchaseError.backendValidationFailed
        }
    }
}
```

## Error Handling

```swift
func purchase(_ product: Product) async throws {
    do {
        let result = try await product.purchase()
        // Handle result
    } catch StoreKitError.userCancelled {
        // User cancelled - not an error, don't show alert
    } catch StoreKitError.networkError {
        // Network issue - retry later
        showRetryableError()
    } catch StoreKitError.systemError {
        // System error - retry later
        showRetryableError()
    } catch {
        // Other error
        throw PurchaseError.purchaseFailed
    }
}
```

## Family Sharing

```swift
// Check if product supports Family Sharing (must be enabled in App Store Connect)
if product.isFamilyShareable {
    // Show family sharing badge
}

// Transaction includes ownership info
let transaction = try checkVerified(result)
if transaction.ownershipType == .familyShared {
    // Content accessed via Family Sharing
    // Can be revoked if user leaves family
}
```

## SwiftUI Views (iOS 17+)

### ProductView

```swift
ProductView(id: "com.app.subscription.monthly") {
    Image("premium-icon")
}
.productViewStyle(.large)  // .automatic, .large, .regular, .compact
```

### StoreView

```swift
StoreView(ids: [
    "com.app.subscription.monthly",
    "com.app.subscription.yearly"
]) { product in
    ProductImage(for: product)
}
.storeButton(.visible, for: .restorePurchases)
.storeButton(.hidden, for: .cancellation)
```

### SubscriptionStoreView

```swift
SubscriptionStoreView(groupID: "YOUR_SUBSCRIPTION_GROUP_ID") {
    VStack {
        Text("Premium Features")
            .font(.title)
        FeatureList()
    }
}
.subscriptionStoreControlStyle(.prominentPicker)
.subscriptionStoreButtonLabel(.multiline)
.containerBackground(.blue.gradient, for: .subscriptionStoreHeader)
```

### View Modifiers

```swift
// Track purchase state
.onInAppPurchaseStart { product in
    // Show loading indicator
}
.onInAppPurchaseCompletion { product, result in
    // Handle completion, dismiss paywall
}

// Monitor subscription status
.subscriptionStatusTask(for: "GROUP_ID") { taskState in
    if let statuses = taskState.value {
        // Update UI based on subscription status
    }
}
```

## App Transaction ID (iOS 18.4+)

Unique identifier for analytics, back-deployed to iOS 15:

```swift
let appTransaction = try await AppTransaction.shared
let appTransactionID = appTransaction.appTransactionID
// Unique per Apple Account per app download
// Stable across reinstalls, refunds, repurchases
```
