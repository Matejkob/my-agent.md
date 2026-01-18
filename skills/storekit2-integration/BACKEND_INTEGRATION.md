# Backend Integration

Complete guide for server-side StoreKit 2 integration.

## JWS Transaction Format

StoreKit 2 transactions are JWS (JSON Web Signature) Compact Serialization:

```
header.payload.signature
```

Each part is Base64-encoded:
- **Header**: Algorithm, key info, **x5c certificate chain**
- **Payload**: Transaction data (JSON) including **environment** field
- **Signature**: Cryptographic signature from Apple

## Backend Verification Requirements

Your backend MUST:

1. **Verify the JWS signature** against the certificate chain
2. **Validate the certificate chain** traces back to Apple Root CA (G3)
3. **Check the environment field** - reject Sandbox receipts in Production
4. **Use originalTransactionID** for database linking
5. **Handle idempotency** - same transaction may arrive multiple times

## Option 1: Local JWS Verification (Faster)

```python
from appstoreserverlibrary.signed_data_verifier import SignedDataVerifier

# Download Apple Root CA from https://www.apple.com/certificateauthority/
apple_root_cert = load_certificate("AppleRootCA-G3.cer")

verifier = SignedDataVerifier(
    root_certificates=[apple_root_cert],
    bundle_id='com.your.app',
    app_apple_id=123456789,
    environment=Environment.PRODUCTION,  # CRITICAL: Match expected environment
    enable_online_checks=True
)

try:
    transaction = verifier.verify_and_decode_transaction(jws_string)

    # CRITICAL: Check environment matches your server
    if transaction.environment != "Production":
        raise SecurityError("Sandbox receipt sent to production!")

    # CRITICAL: Check for revocation
    if transaction.revocation_date is not None:
        revoke_entitlement(transaction.original_transaction_id)
        return

    # Use originalTransactionID for database
    grant_entitlement(
        user_id=get_user_from_app_account_token(transaction.app_account_token),
        original_transaction_id=transaction.original_transaction_id,
        product_id=transaction.product_id
    )
except VerificationError as e:
    # Signature invalid - reject
    raise
```

### Certificate Chain Validation

The JWS header contains an `x5c` field with the certificate chain. You MUST verify:
1. The leaf certificate signed the JWS
2. Each certificate is signed by the next
3. The root certificate is Apple Root CA (G3)

**Without this, attackers can sign fake receipts with their own certificates.**

## Option 2: App Store Server API

Call Apple's API for additional data: full history, subscription status, refunds.

### Authentication

All requests require a JWT signed with your private key from App Store Connect.

#### Getting Credentials

1. **App Store Connect** > **Users and Access** > **Integrations** > **In-App Purchase**
2. Generate an API Key (requires Admin role)
3. Download the `.p8` private key file
4. Note your **Key ID** and **Issuer ID**

#### JWT Structure

Header:
```json
{
  "alg": "ES256",
  "kid": "YOUR_KEY_ID",
  "typ": "JWT"
}
```

Payload:
```json
{
  "iss": "YOUR_ISSUER_ID",
  "iat": 1234567890,
  "exp": 1234571490,
  "aud": "appstoreconnect-v1",
  "bid": "com.your.bundleid"
}
```

### Base URLs

| Environment | Base URL |
|-------------|----------|
| Production | `https://api.storekit.itunes.apple.com` |
| Sandbox | `https://api.storekit-sandbox.itunes.apple.com` |

**Note:** Production endpoint with Sandbox transactionId returns error `4040010`. Fall back to Sandbox endpoint.

### Key Endpoints

#### Get Transaction Info

```http
GET /inApps/v1/transactions/{transactionId}
Authorization: Bearer {JWT}
```

#### Get Transaction History

```http
GET /inApps/v1/history/{originalTransactionId}
Authorization: Bearer {JWT}
```

Returns complete transaction history. Use `originalTransactionId`.

#### Get Subscription Statuses

```http
GET /inApps/v1/subscriptions/{originalTransactionId}
Authorization: Bearer {JWT}
```

Returns subscription statuses for subscription groups associated with the original transaction.

Query parameters:
- `status=1` - Active
- `status=2` - Expired
- `status=3` - Billing retry
- `status=4` - Grace period
- `status=5` - Revoked

#### Send Consumption Information

```http
PUT /inApps/v1/transactions/consumption/{transactionId}
Authorization: Bearer {JWT}
```

**Provides consumption data to Apple** for refund decisions. Does NOT initiate refunds.

### Using Apple's Server Library (Swift)

```swift
import AppStoreServerLibrary

let privateKey = try String(contentsOfFile: "AuthKey.p8")

let client = try AppStoreServerAPIClient(
    signingKey: privateKey,
    keyId: "YOUR_KEY_ID",
    issuerId: "YOUR_ISSUER_ID",
    bundleId: "com.your.app",
    environment: .production
)

// Get transaction history using originalTransactionId
let response = try await client.getTransactionHistory(
    transactionId: "original_transaction_id",
    revision: nil
)

// Verify signed transaction
let verifier = try SignedDataVerifier(
    rootCertificates: [appleRootCertificate],
    bundleId: "com.your.app",
    appAppleId: 123456789,
    environment: .production,
    enableOnlineChecks: true
)

let transaction = try verifier.verifyAndDecodeTransaction(
    signedTransaction: jwsString
)
```

## Server Notifications V2

Real-time updates from App Store. **Best-effort delivery** - poll API to reconcile.

### Setup in App Store Connect

1. **App Store Connect** > **My Apps** > **Your App**
2. **App Information** > **App Store Server Notifications**
3. Enter **Production Server URL** (HTTPS required)
4. Enter **Sandbox Server URL**
5. Select **Version 2**

### Notification Payload

```json
{
  "signedPayload": "eyJhbGciOiJFUzI1NiIsIng1YyI6WyJNSUlF..."
}
```

### Notification Types

| Type | Subtype | Description |
|------|---------|-------------|
| `SUBSCRIBED` | `INITIAL_BUY` / `RESUBSCRIBE` | New subscription |
| `DID_RENEW` | - | Renewal succeeded |
| `DID_FAIL_TO_RENEW` | `GRACE_PERIOD` / `BILLING_RETRY` | Renewal failed |
| `DID_CHANGE_RENEWAL_STATUS` | `AUTO_RENEW_ENABLED` / `DISABLED` | Auto-renew toggled |
| `DID_CHANGE_RENEWAL_PREF` | `UPGRADE` / `DOWNGRADE` | Plan change scheduled |
| `EXPIRED` | `VOLUNTARY` / `BILLING_RETRY` / `PRICE_INCREASE` | Subscription expired |
| `GRACE_PERIOD_EXPIRED` | - | Grace period ended |
| `OFFER_REDEEMED` | Various | Promotional offer applied |
| `REFUND` | - | Transaction refunded |
| `REFUND_DECLINED` | - | Refund request declined |
| `REFUND_REVERSED` | - | Refund reversed |
| `CONSUMPTION_REQUEST` | - | Apple requesting consumption data |
| `RENEWAL_EXTENDED` | - | Subscription extended |
| `REVOKE` | - | Family Sharing revoked |
| `PRICE_INCREASE` | `PENDING` / `ACCEPTED` | Price increase consent |
| `ONE_TIME_CHARGE` | - | Consumable (Sandbox only) |

### Backend Handler Example

```python
from appstoreserverlibrary.signed_data_verifier import SignedDataVerifier

@app.route('/webhooks/appstore', methods=['POST'])
def handle_appstore_notification():
    payload = request.json.get('signedPayload')

    verifier = SignedDataVerifier(
        root_certificates=[apple_root_cert],
        bundle_id='com.your.app',
        app_apple_id=123456789,
        environment=Environment.PRODUCTION,
        enable_online_checks=True
    )

    notification = verifier.verify_and_decode_notification(payload)

    notification_type = notification.notification_type
    subtype = notification.subtype
    data = notification.data

    # CRITICAL: Use originalTransactionId for database operations
    original_tx_id = data.signed_transaction_info.original_transaction_id

    if notification_type == 'DID_RENEW':
        handle_renewal(original_tx_id, data)
    elif notification_type == 'REFUND':
        revoke_entitlement(original_tx_id)
    elif notification_type == 'EXPIRED':
        handle_expiration(original_tx_id, subtype)
    elif notification_type == 'REVOKE':
        # Family Sharing revoked
        revoke_entitlement(original_tx_id)
    # ... handle other types

    return '', 200  # Return 200 to acknowledge
```

### Reconciliation Job

Since notifications aren't guaranteed, run periodic reconciliation:

```python
def reconcile_subscriptions():
    """Run daily to catch missed notifications"""
    for user in get_users_with_subscriptions():
        response = app_store_api.get_subscription_statuses(
            user.original_transaction_id
        )
        for status in response.data:
            update_subscription_state(user, status)
```

## Testing Environment Certificates

**Important:** Xcode StoreKit uses **self-signed certificates**, not Apple Root CA.

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

## Apple Server Libraries

- [Swift](https://github.com/apple/app-store-server-library-swift)
- [Node.js](https://github.com/apple/app-store-server-library-node)
- [Python](https://github.com/apple/app-store-server-library-python)
- [Java](https://github.com/apple/app-store-server-library-java)
