import SwiftUI
import CopiedKit

/// Phase 11 — lets a user who bought Copied through the Mac License
/// (Stripe) path unlock iCloud Sync on iOS without paying twice. The
/// JWT they received from Stripe Checkout (either raw or wrapped in a
/// `copied://unlock?key=<jwt>` URL) is pasted here, Ed25519-verified
/// against the same public key the Mac uses, and on success flips
/// `iCloudSyncPurchased = true` via the cross-platform `LicenseStore`.
///
/// A license that decodes + verifies successfully is persisted to
/// Keychain so the unlock survives reinstall — identical behaviour to
/// the Mac License build.
struct LicenseEntrySheet: View {
    let onSuccess: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var raw: String = ""
    @State private var errorMessage: String?
    @State private var isVerifying: Bool = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Paste license or copied:// URL", text: $raw, axis: .vertical)
                        .lineLimit(3...8)
                        .font(.callout.monospaced())
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("License")
                } footer: {
                    Text("Either form works: the raw JWT (\"eyJ…\") or the full copied://unlock?key=… URL from your purchase email.")
                }

                if let err = errorMessage {
                    Section {
                        Label(err, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(Color.copiedRed)
                            .font(.footnote)
                    }
                }

                Section {
                    Button {
                        verify()
                    } label: {
                        HStack {
                            Text("Unlock iCloud Sync")
                                .font(.body.weight(.semibold))
                            Spacer()
                            if isVerifying {
                                ProgressView()
                            }
                        }
                        .foregroundStyle(.white)
                    }
                    .listRowBackground(Color.copiedTeal)
                    .disabled(raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isVerifying)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.copiedCanvas)
            .navigationTitle("Enter License")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(Color.copiedTeal)
                }
            }
            .tint(.copiedTeal)
            .preferredColorScheme(.dark)
        }
    }

    private func verify() {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let jwt = extractJWT(from: trimmed)
        guard !jwt.isEmpty else {
            errorMessage = "That doesn't look like a license. Paste the full JWT or the copied://unlock URL from your purchase email."
            return
        }
        isVerifying = true
        errorMessage = nil
        // Do the verification on the main actor — LicenseValidator is
        // CPU-bound Ed25519 which takes microseconds, so we don't need
        // to hop to a background queue.
        Task { @MainActor in
            do {
                let payload = try LicenseStore.storeAndVerify(license: jwt)
                isVerifying = false
                onSuccess(payload.email)
                dismiss()
            } catch LicenseValidator.VerifyError.badSignature {
                isVerifying = false
                errorMessage = "Signature check failed. The license may be corrupted — copy it again from your purchase email."
            } catch LicenseValidator.VerifyError.badPayload {
                isVerifying = false
                errorMessage = "License data is invalid. Check with support if this keeps happening."
            } catch LicenseValidator.VerifyError.wrongProduct {
                isVerifying = false
                errorMessage = "This license is for a different Copied product. iOS only accepts iCloud Sync licenses."
            } catch LicenseValidator.VerifyError.malformed {
                isVerifying = false
                errorMessage = "That doesn't look like a Copied license."
            } catch {
                isVerifying = false
                errorMessage = "Couldn't save the license: \(error.localizedDescription)"
            }
        }
    }

    /// Accept either a raw JWT (`base64.base64`) or a `copied://unlock?key=…`
    /// URL. We deliberately don't accept `https://` URLs — the license
    /// never leaves the offline verifier, and a URL that lands on a web
    /// page would surprise the user.
    private func extractJWT(from input: String) -> String {
        if input.hasPrefix("copied://") || input.hasPrefix("copied:") {
            if let url = URL(string: input),
               let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
               let key = components.queryItems?.first(where: { $0.name == "key" })?.value {
                return key
            }
            return ""
        }
        // Naive but sufficient: a license is exactly two base64url chunks
        // separated by one dot. Anything else is almost certainly not a
        // license.
        let parts = input.split(separator: ".")
        guard parts.count == 2 else { return "" }
        return input
    }
}
