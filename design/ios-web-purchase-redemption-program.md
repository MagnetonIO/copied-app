# Website Purchase to iOS Redemption

## Intended Customer Flow

1. Customer buys Copied iCloud Sync through the website.
2. Verify the captured, paid Stripe purchase for the exact Copied product and
   normalized purchase email. Refunds, disputes and failed payments are ineligible.
3. Reserve one Apple-generated, one-time IAP offer code for that customer.
4. Send its private Apple redemption URL and iOS download/restore instructions.
5. Apple redemption grants the StoreKit entitlement. No external license key is
   accepted by the iOS app. A forwarded code can be redeemed by its first recipient;
   Apple codes are not bound to the website buyer's email address.

App Store purchasers continue to use Apple purchase/restore and need no website code.

## November 3 Setup

- Apple IAP: `6764169200` / `com.magneton.copied.icloud_sync`.
- Attempted Apple offer name: `Copied Website Purchasers - iOS Sync`.
- Free offer, all currently offered storefronts, all three Apple purchase-history
  eligibility categories. The admin, not a public reusable code, controls recipients.
- Apple returned HTTP 500 `UNEXPECTED_ERROR` on offer creation, including retry.
  The dialog was cancelled; no successful Apple offer or code batch is confirmed.
- Admin sandbox campaign: `10543744-26a5-489a-9bcb-1f2960b609fb`.
- Admin production campaign: `360d3a70-c3d8-4c14-88bb-43249fc17c09`.
- Campaign name: `Website Purchasers - iOS Sync - Nov 2026`.
- Both campaigns remain disabled and contain no imported codes. The May 1, 2027
  expiry is provisional and must match the actual Apple batch before any activation.
- These initial migration campaigns cover purchases through their creation cutoff.
  They do not yet implement automatic fulfillment for later website purchases.

## Activation Gates

- Resolve Apple offer creation and import real sandbox codes; never fabricate codes.
- Verify sandbox redemption, StoreKit updates, unlock, reinstall and restore on
  iPhone and iPad. Sandbox/TestFlight purchases do not prove production ownership.
- Confirm iOS production availability and perform a real production redemption.
- Validate email inbox receipt, recipient binding, refund/dispute checks, duplicate
  handling, expiry, inventory exhaustion and retries without reassigning a code.
- Record external validation evidence; then explicitly enable production sending.
- Establish the ongoing fulfillment model and confirm App Review compatibility
  before promising automatic iOS access with future website purchases. The existing
  frozen-cutoff migration campaigns are not a perpetual fulfillment mechanism.

No customer codes or redemption emails were sent during setup. Existing Mac license
delivery and payment webhooks were not replaced.
