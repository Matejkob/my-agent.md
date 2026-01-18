# Subscription Management

Complete guide for managing subscription states, billing, and offers.

## Subscription States

```swift
func checkSubscriptionStatus(for product: Product) async {
    guard let subscription = product.subscription,
          let statuses = try? await subscription.status else {
        return
    }

    for status in statuses {
        switch status.state {
        case .subscribed:
            // Active subscription
            grantAccess()

        case .expired:
            // Subscription ended
            revokeAccess()

        case .inBillingRetryPeriod:
            // Payment failed, Apple retrying for up to 60 days
            if let renewalInfo = try? checkVerified(status.renewalInfo),
               renewalInfo.gracePeriodExpiresDate != nil,
               renewalInfo.gracePeriodExpiresDate! > Date() {
                // Grace period active - maintain access
                grantAccess()
                showBillingIssueReminder()
            } else {
                // No grace period - revoke access
                revokeAccess()
                showBillingRetryNotice()
            }

        case .inGracePeriod:
            // Grace period active - maintain access
            grantAccess()
            showBillingIssueReminder()

        case .revoked:
            // Refunded or Family Sharing revoked
            revokeAccessImmediately()

        @unknown default:
            break
        }
    }
}
```

## Billing Grace Period

Configure in App Store Connect to retain subscribers during billing issues.

### Duration Options

| Your Selection | Weekly Subscriptions | Other Subscriptions |
|----------------|---------------------|---------------------|
| 3 days | 3 days | 3 days |
| 16 days | 6 days (capped) | 16 days |
| 28 days | 6 days (capped) | 28 days |

**Weekly cap:** Even with 16/28 day selection, weekly subscriptions are capped at 6 days.

### During Grace Period

- User retains access to content
- Apple attempts to collect payment
- Show soft paywall/reminder to user

## Billing Retry

When payment fails:
- Apple retries for **60 days**
- Without grace period: user loses access immediately
- With grace period: user retains access during grace period only

## Upgrade/Downgrade Handling

Subscriptions within the same group can be changed:

```swift
if let renewalInfo = try? checkVerified(status.renewalInfo) {
    if renewalInfo.willAutoRenew {
        if let pendingProductId = renewalInfo.autoRenewPreference,
           pendingProductId != currentProductId {
            // User has scheduled a change
            showPendingChangeNotice(newProductId: pendingProductId)
        }
    }
}
```

## Introductory Offers

First-time subscriber discounts:

```swift
// Check eligibility
let isEligible = await product.subscription?.isEligibleForIntroOffer ?? false

// Display offer info
if let introOffer = product.subscription?.introductoryOffer {
    let price = introOffer.displayPrice
    let period = introOffer.period  // .day, .week, .month, .year
    let periodCount = introOffer.periodCount
    let paymentMode = introOffer.paymentMode  // .freeTrial, .payAsYouGo, .payUpFront
}
```

### Payment Modes

| Mode | Description |
|------|-------------|
| `.freeTrial` | Free for intro period, then regular price |
| `.payAsYouGo` | Reduced price per period during intro |
| `.payUpFront` | One-time reduced payment for intro period |

## Promotional Offers

Targeted offers for existing/lapsed subscribers:

### Setup

1. **Configure in App Store Connect** - Up to 10 active offers per subscription
2. **Generate JWS signature on server** - Required for security (iOS 18.4+ APIs)
3. **Apply during purchase**

### Implementation

```swift
// Server generates JWS signature using App Store Server Library
let signature = await fetchSignatureFromServer(
    productID: product.id,
    offerID: "special_offer_1"
)

// Apply offer during purchase
let result = try await product.purchase(options: [
    .promotionalOffer(
        offerID: "special_offer_1",
        signature: signature
    )
])
```

### Server-Side Signature Generation (Swift)

```swift
import AppStoreServerLibrary

let signatureCreator = PromotionalOfferSignatureCreator(
    privateKey: privateKeyPEM,
    keyId: "YOUR_KEY_ID",
    bundleId: "com.your.app"
)

let signature = try signatureCreator.createSignature(
    productIdentifier: "com.app.subscription.monthly",
    offerIdentifier: "special_offer_1",
    applicationUsername: userUUID.uuidString,
    nonce: UUID(),
    timestamp: Date().timeIntervalSince1970
)
```

## Win-Back Offers (iOS 18+)

Target lapsed subscribers:

```swift
// Check for available win-back offers
if let winbackOffers = product.subscription?.winBackOffers {
    for offer in winbackOffers {
        // Display win-back offer to lapsed subscriber
    }
}
```

## Product Types for Rentals

Apple doesn't have a "rental" type. Options:

| Option | Pros | Cons |
|--------|------|------|
| **Consumable** | Simple, immediate | Cannot restore; lost on reinstall without server |
| **Non-Renewing Subscription** | Apple tracks duration; can restore | More complex setup |

**Recommendation:** Use **Non-Renewing Subscription** for rentals, or **Consumable** with robust server-side entitlement tracking.

## appAccountToken Best Practice

Always include to link purchases to your users:

```swift
// Generate stable UUID per user on your server
let userUUID = user.storeKitUUID  // Store in user database

let result = try await product.purchase(options: [
    .appAccountToken(userUUID)
])

// UUID is embedded in JWS and returned in:
// - Purchase transaction
// - All renewal transactions
// - Server Notifications
```

## Offline Behavior

`Transaction.currentEntitlements` caches locally but:
- May be stale (not real-time)
- Won't include purchases from other devices until online
- Won't reflect recent refunds until online

```swift
// Returns cached data - may not be current
for await result in Transaction.currentEntitlements {
    // Use for offline access, verify with backend when online
}
```

## Verification Best Practices

1. **Verify on device first** using `VerificationResult` (signature integrity)
2. **Send JWS to backend** for server-side validation
3. **Don't trust client-only verification** for premium content
4. **Backend is source of truth** for entitlements
