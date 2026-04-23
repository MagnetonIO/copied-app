import SwiftUI
import StoreKit
import CopiedKit

/// The iCloud Sync paywall + status screen. Three modes:
/// 1. Not purchased → paywall CTA + Restore Purchases.
/// 2. Purchased, toggle off → "Enable iCloud Sync" toggle.
/// 3. Purchased + enabled → status from `SyncMonitor`.
///
/// Uses the shared `PurchaseManager` in `CopiedKit` — same `iCloudSyncPurchased`
/// UserDefaults key as Mac, so a user with Family Sharing or Restore Purchases
/// on both platforms sees one consistent unlocked state.
struct SyncScreen: View {
    @AppStorage("iCloudSyncPurchased") private var purchased = false
    @AppStorage("cloudSyncEnabled") private var cloudSyncEnabled = true

    // Shared singleton; `@State` keeps the reference stable across view rebuilds
    // so `.task { await pm.loadProduct() }` runs exactly once per mount.
    @State private var pm = PurchaseManager.shared
    @State private var lastActionMessage: String?
    /// Lifted to `SettingsSheet` so the sheet attaches to the root
    /// NavigationStack — iOS 26 doesn't reliably present sheets attached
    /// to views inside a NavigationStack that is itself inside a sheet.
    @Binding var presentsLicenseEntry: Bool
    @Binding var licenseBanner: String?

    var body: some View {
        Form {
            // R-2 HIGH-1: the ModelContainer was built at app launch with
            // cloudSync gated on purchased+toggle. After a mid-session
            // unlock the container is stale — UI says "Active" but writes
            // don't actually use CloudKit until a cold relaunch.
            if SharedIOSData.requiresRelaunchForSync {
                relaunchRequiredSection
            }

            if !purchased {
                paywallSection
            } else {
                toggleSection
                if purchased && cloudSyncEnabled {
                    statusSection
                }
            }

            Section {
                Button("Restore Purchases") {
                    Task {
                        let ok = await pm.restore()
                        lastActionMessage = ok ? "Restored." : (pm.lastError ?? "No previous purchase.")
                    }
                }
                .disabled(pm.purchaseInFlight)
                .foregroundStyle(Color.copiedTeal)

                Button("Enter License Key") {
                    presentsLicenseEntry = true
                }
                .foregroundStyle(Color.copiedTeal)
            } footer: {
                Text("Bought a license for the Mac Direct version (outside the App Store)? Enter it here to unlock iCloud Sync on iOS too.")
            }

            if let msg = lastActionMessage {
                Section {
                    Text(msg)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color.copiedCanvas)
        .navigationTitle("iCloud Sync")
        .tint(.copiedTeal)
        .preferredColorScheme(.dark)
        .task { await pm.loadProduct() }
        .onChange(of: licenseBanner) { _, new in
            // `LicenseEntrySheet` dismisses itself on success; we observe
            // the banner string set by `SettingsSheet` so the sync screen
            // reflects the unlock immediately without a second round-trip.
            if let new { lastActionMessage = new; licenseBanner = nil }
        }
    }

    // MARK: - Relaunch required banner

    @ViewBuilder
    private var relaunchRequiredSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Image(systemName: "arrow.clockwise.circle.fill")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(Color.copiedTeal)
                    Text("Restart required")
                        .font(.subheadline.weight(.semibold))
                }
                Text("iCloud Sync unlocked successfully. Force-quit Copied (swipe up from the app switcher) and reopen it so new clippings start syncing to iCloud.")
                    .font(.caption)
                    .foregroundStyle(Color.copiedSecondaryLabel)
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: - Paywall

    @ViewBuilder
    private var paywallSection: some View {
        Section {
            VStack(spacing: 12) {
                Image(systemName: "icloud.and.arrow.up")
                    .font(.system(size: 44, weight: .light))
                    .foregroundStyle(Color.copiedTeal)
                Text("Unlock iCloud Sync")
                    .font(.title2.weight(.semibold))
                Text("Every clipping you save on this iPhone shows up on your Mac and iPad automatically. A one-time purchase — no subscription.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .listRowBackground(Color.clear)
        }

        Section {
            Button {
                Task {
                    let ok = await pm.purchase()
                    if !ok, let err = pm.lastError { lastActionMessage = err }
                }
            } label: {
                HStack {
                    Text("Unlock")
                        .font(.body.weight(.semibold))
                    Spacer()
                    if let price = pm.product?.displayPrice {
                        Text(price)
                            .font(.body.weight(.semibold))
                    }
                }
                .padding(.vertical, 4)
                .foregroundStyle(.white)
            }
            .listRowBackground(Color.copiedTeal)
            .disabled(pm.purchaseInFlight || pm.product == nil)
        } footer: {
            Text("A family member's purchase can be restored — tap Restore Purchases below.")
        }
    }

    // MARK: - Toggle

    @ViewBuilder
    private var toggleSection: some View {
        Section {
            Toggle("iCloud Sync", isOn: $cloudSyncEnabled)
        } footer: {
            Text("Syncs via your iCloud account. Turning off disconnects this device from the shared history.")
        }
    }

    // MARK: - Status

    @ViewBuilder
    private var statusSection: some View {
        Section("Status") {
            HStack {
                Image(systemName: "checkmark.icloud.fill")
                    .foregroundStyle(Color.copiedTeal)
                Text("Active")
                    .foregroundStyle(.primary)
                Spacer()
            }
        }
    }
}
