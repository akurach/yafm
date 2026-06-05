import SwiftUI
import Core

// MARK: - Access onboarding (§6)
//
// yafm is non-sandboxed but still bound by TCC. Without Full Disk Access some
// folders (Mail, Safari, others) read back empty. The "never freeze silently"
// principle extends to permissions: explain it, never show an unexplained blank.

/// First-run sheet: why access is needed + a button into System Settings.
struct OnboardingSheet: View {
    let app: AppState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "lock.shield")
                    .font(.system(size: 30))
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Welcome to yafm").font(.title2.bold())
                    Text("A fast, honest file manager.").foregroundStyle(.secondary)
                }
            }

            Divider()

            Text("Grant Full Disk Access")
                .font(.headline)
            Text("""
                 macOS hides some folders (Mail, Safari, and other protected \
                 locations) until you grant access. yafm only reads files you \
                 open, to show and copy them — but without access those folders \
                 look empty instead of explaining why.
                 """)
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Label(app.hasFullDiskAccess ? "Full Disk Access is enabled" : "Full Disk Access is off",
                  systemImage: app.hasFullDiskAccess ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(app.hasFullDiskAccess ? .green : .orange)
                .font(.callout)

            Text("Removable and network volumes prompt on first use — that system dialog is normal.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if !app.hasFullDiskAccess {
                Text("After granting access, relaunch yafm so it can see the new folders.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            HStack {
                Button("Open System Settings…") { app.openFullDiskAccessSettings() }
                Spacer()
                Button("Continue") { app.completeOnboarding(); dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}

/// Non-intrusive banner shown above the panes while access is limited. yafm
/// keeps working in the available scope — this is a hint, not a wall.
struct AccessBanner: View {
    let app: AppState

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text("Limited access — some folders are hidden.")
                .font(.callout)
            Button("Enable Full Disk Access") { app.openFullDiskAccessSettings() }
                .buttonStyle(.link)
            Spacer()
            Button { app.bannerDismissed = true } label: { Image(systemName: "xmark") }
                .buttonStyle(.plain).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(.yellow.opacity(0.18))
    }
}
