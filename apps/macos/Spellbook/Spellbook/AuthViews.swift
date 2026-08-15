import SwiftUI

struct AuthFlowView: View {
    @EnvironmentObject private var sessionModel: SessionModel

    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor).ignoresSafeArea()

            switch sessionModel.authScreen {
            case .welcome:
                WelcomeView()
            case .email:
                EmailSignInView()
            case .otp(let email):
                OTPView(email: email)
            }
        }
    }
}

private struct WelcomeView: View {
    @EnvironmentObject private var sessionModel: SessionModel

    var body: some View {
        VStack(spacing: 26) {
            VStack(spacing: 10) {
                Text("Raddus Spellbook")
                    .font(.system(size: 42, weight: .semibold))
                Text("Spellbook installs versioned agent instructions into local projects and shares the ones you publish.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 540)
            }

            HStack(alignment: .top, spacing: 16) {
                WelcomeWorkflowColumn(
                    title: "Capture",
                    steps: [
                        "Create or install an instruction",
                        "Publish it for a stable uid",
                        "Keep a versioned SPEC.md snapshot"
                    ]
                )

                WelcomeWorkflowColumn(
                    title: "Install",
                    steps: [
                        "Choose a target directory",
                        "Enable one or more harnesses",
                        "Pin uid and version references"
                    ]
                )

                WelcomeWorkflowColumn(
                    title: "Share",
                    steps: [
                        "Publish useful spells",
                        "Send a public link",
                        "Let others install them"
                    ]
                )
            }
            .padding(18)
            .frame(maxWidth: 720)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.gray.opacity(0.22), lineWidth: 1))

            Button {
                sessionModel.authScreen = .email
            } label: {
                Label("Sign In", systemImage: "envelope")
                    .frame(width: 180)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .padding(48)
    }
}

private struct WelcomeWorkflowColumn: View {
    var title: String
    var steps: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)

            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Text("\(index + 1).")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 16, alignment: .trailing)

                        Text(step)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

private struct EmailSignInView: View {
    @EnvironmentObject private var sessionModel: SessionModel
    @State private var email = ""
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 18) {
            Text("Spellbook")
                .font(.largeTitle.bold())

            TextField("Email", text: $email)
                .textFieldStyle(.roundedBorder)
                .frame(width: 360)
                .onSubmit { sendCode() }

            HStack {
                Button("Back") {
                    sessionModel.authScreen = .welcome
                }

                Button {
                    sendCode()
                } label: {
                    Label(isLoading ? "Sending" : "Sign In", systemImage: "paperplane")
                        .frame(width: 120)
                }
                .buttonStyle(.borderedProminent)
                .disabled(isLoading || email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(44)
        .spellbookErrorAlert(message: $errorMessage)
    }

    private func sendCode() {
        let normalized = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else {
            return
        }

        isLoading = true
        errorMessage = nil

        Task {
            do {
                try await SpellbookAPI.shared.requestOTP(email: normalized)
                await MainActor.run {
                    isLoading = false
                    sessionModel.authScreen = .otp(email: normalized)
                }
            } catch {
                await MainActor.run {
                    isLoading = false
                    errorMessage = error.localizedDescription
                }
            }
        }
    }
}

private struct OTPView: View {
    @EnvironmentObject private var sessionModel: SessionModel
    let email: String

    @State private var digits = Array(repeating: "", count: 6)
    @State private var isLoading = false
    @State private var errorMessage: String?
    @FocusState private var focusedIndex: Int?

    private var code: String {
        digits.joined()
    }

    var body: some View {
        VStack(spacing: 18) {
            Text("Enter Code")
                .font(.largeTitle.bold())

            Text(email)
                .foregroundStyle(.secondary)

            HStack(spacing: 10) {
                ForEach(0..<6, id: \.self) { index in
                    TextField("", text: digitBinding(for: index))
                        .font(.system(size: 26, weight: .semibold, design: .monospaced))
                        .multilineTextAlignment(.center)
                        .frame(width: 44, height: 48)
                        .textFieldStyle(.plain)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color(nsColor: .textBackgroundColor))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(focusedIndex == index ? Color.accentColor : Color.gray.opacity(0.28), lineWidth: 1)
                        )
                        .focused($focusedIndex, equals: index)
                }
            }

            HStack {
                Button("Change Email") {
                    sessionModel.authScreen = .email
                }

                Button {
                    resendCode()
                } label: {
                    Label("Resend Code", systemImage: "arrow.clockwise")
                }
                .disabled(isLoading)

                Button {
                    verify()
                } label: {
                    Label(isLoading ? "Verifying" : "Verify", systemImage: "checkmark")
                        .frame(width: 100)
                }
                .buttonStyle(.borderedProminent)
                .disabled(isLoading || code.count != 6)
            }
        }
        .padding(44)
        .onAppear {
            focusedIndex = 0
        }
        .spellbookErrorAlert(message: $errorMessage)
    }

    private func digitBinding(for index: Int) -> Binding<String> {
        Binding(
            get: { digits[index] },
            set: { newValue in
                let numbers = newValue.filter(\.isNumber)
                if numbers.count > 1 {
                    applyPastedCode(String(numbers.prefix(6)))
                    return
                }

                digits[index] = String(numbers.prefix(1))
                if !digits[index].isEmpty {
                    focusedIndex = min(index + 1, 5)
                }
            }
        )
    }

    private func applyPastedCode(_ pasted: String) {
        for (index, character) in pasted.enumerated() where index < digits.count {
            digits[index] = String(character)
        }
        focusedIndex = min(pasted.count, 5)
    }

    private func resendCode() {
        isLoading = true
        errorMessage = nil

        Task {
            do {
                try await SpellbookAPI.shared.requestOTP(email: email)
                await MainActor.run {
                    isLoading = false
                    digits = Array(repeating: "", count: 6)
                    focusedIndex = 0
                }
            } catch {
                await MainActor.run {
                    isLoading = false
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func verify() {
        isLoading = true
        errorMessage = nil

        Task {
            do {
                let session = try await SpellbookAPI.shared.verifyOTP(email: email, code: code)
                try await MainActor.run {
                    try sessionModel.completeSignIn(session)
                    isLoading = false
                }
            } catch {
                await MainActor.run {
                    isLoading = false
                    errorMessage = error.localizedDescription
                }
            }
        }
    }
}
