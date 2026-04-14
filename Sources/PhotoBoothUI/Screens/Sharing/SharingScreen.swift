// SharingScreen.swift
// Sharing station with email, SMS, QR code, AirDrop, and print options.

import SwiftUI
import CoreImage.CIFilterBuiltins

/// The sharing station presents a grid of sharing options. Each option leads
/// to an inline input flow (email/phone entry, QR display, etc.).
public struct SharingScreen: View {

    let session: BoothSession

    @State private var selectedOption: SharingOption?
    @State private var emailInput: String = ""
    @State private var phoneInput: String = ""
    @State private var isProcessing: Bool = false
    @State private var showSuccess: Bool = false
    @State private var qrCodeImage: UIImage?

    private let columns = [
        GridItem(.adaptive(minimum: 160, maximum: 200), spacing: 20)
    ]

    public init(session: BoothSession) {
        self.session = session
    }

    public var body: some View {
        ZStack {
            // Background
            LinearGradient(
                colors: [Color.black, session.config.primaryColor.opacity(0.3)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            if let option = selectedOption {
                // Detail view for selected sharing option
                sharingDetailView(for: option)
                    .transition(.boothSlide(edge: .trailing))
            } else {
                // Grid of sharing options
                sharingGrid
                    .transition(.boothSlide(edge: .leading))
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: selectedOption)
    }

    // MARK: - Sharing Grid

    private var sharingGrid: some View {
        VStack(spacing: 32) {
            // Header
            VStack(spacing: 8) {
                Text("Share Your Photos")
                    .font(.system(size: 38, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)

                Text("Choose how you'd like to receive your photos")
                    .font(.title3)
                    .foregroundStyle(.white.opacity(0.7))
            }
            .padding(.top, 80)

            // Preview thumbnail strip
            photoPreviewStrip
                .padding(.horizontal, 40)

            // Options grid
            LazyVGrid(columns: columns, spacing: 20) {
                ForEach(SharingOption.allCases) { option in
                    if session.config.enabledSharingOptions.contains(option) {
                        SharingOptionCard(option: option) {
                            selectOption(option)
                        }
                    }
                }
            }
            .padding(.horizontal, 40)

            Spacer()

            // Skip/done button
            Button("Skip") {
                session.navigate(to: .thankYou)
            }
            .buttonStyle(BoothSecondaryButtonStyle())
            .padding(.bottom, 60)
        }
    }

    // MARK: - Photo Preview Strip

    private var photoPreviewStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(Array(session.capturedImages.enumerated()), id: \.offset) { index, image in
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 80, height: 80)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .strokeBorder(.white.opacity(0.3), lineWidth: 1)
                        )
                        .accessibilityLabel(Text("Photo \(index + 1)"))
                }
            }
        }
        .frame(height: 80)
    }

    // MARK: - Detail Views

    @ViewBuilder
    private func sharingDetailView(for option: SharingOption) -> some View {
        VStack(spacing: 24) {
            // Back button
            HStack {
                Button {
                    withAnimation {
                        selectedOption = nil
                    }
                } label: {
                    Label("Back", systemImage: "chevron.left")
                        .font(.title3)
                        .foregroundStyle(.white)
                }
                .accessibilityLabel(Text("Go back to sharing options"))
                Spacer()
            }
            .padding(.horizontal, 24)
            .padding(.top, 60)

            switch option {
            case .email:
                emailInputView
            case .sms:
                smsInputView
            case .qrCode:
                qrCodeView
            case .airdrop:
                airdropView
            case .print:
                printView
            }

            Spacer()
        }
    }

    // MARK: - Email Input

    private var emailInputView: some View {
        VStack(spacing: 24) {
            Image(systemName: "envelope.fill")
                .font(.system(size: 60))
                .foregroundStyle(.blue)

            Text("Enter Your Email")
                .font(.title.bold())
                .foregroundStyle(.white)

            TextField("your@email.com", text: $emailInput)
                .textFieldStyle(BoothTextFieldStyle())
                .keyboardType(.emailAddress)
                .textContentType(.emailAddress)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .frame(maxWidth: 500)
                .accessibilityLabel(Text("Email address"))

            Button {
                submitEmail()
            } label: {
                Label("Send", systemImage: "paperplane.fill")
            }
            .buttonStyle(BoothPrimaryButtonStyle())
            .disabled(emailInput.isEmpty || !emailInput.contains("@"))
            .opacity(emailInput.isEmpty || !emailInput.contains("@") ? 0.5 : 1.0)
        }
        .padding(.horizontal, 40)
    }

    // MARK: - SMS Input

    private var smsInputView: some View {
        VStack(spacing: 24) {
            Image(systemName: "message.fill")
                .font(.system(size: 60))
                .foregroundStyle(.green)

            Text("Enter Your Phone Number")
                .font(.title.bold())
                .foregroundStyle(.white)

            TextField("(555) 123-4567", text: $phoneInput)
                .textFieldStyle(BoothTextFieldStyle())
                .keyboardType(.phonePad)
                .textContentType(.telephoneNumber)
                .frame(maxWidth: 500)
                .accessibilityLabel(Text("Phone number"))

            Button {
                submitSMS()
            } label: {
                Label("Send", systemImage: "paperplane.fill")
            }
            .buttonStyle(BoothPrimaryButtonStyle(color: .green))
            .disabled(phoneInput.count < 10)
            .opacity(phoneInput.count < 10 ? 0.5 : 1.0)
        }
        .padding(.horizontal, 40)
    }

    // MARK: - QR Code

    private var qrCodeView: some View {
        VStack(spacing: 24) {
            Text("Scan to Download")
                .font(.title.bold())
                .foregroundStyle(.white)

            Text("Point your phone's camera at the code below")
                .font(.body)
                .foregroundStyle(.white.opacity(0.7))

            if let qrImage = qrCodeImage {
                Image(uiImage: qrImage)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: 250, height: 250)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .shadow(color: .purple.opacity(0.4), radius: 20)
                    .transition(.scale.combined(with: .opacity))
                    .accessibilityLabel(Text("QR code to download your photos"))
            } else {
                ProgressView()
                    .tint(.white)
                    .scaleEffect(1.5)
                    .frame(width: 250, height: 250)
            }

            Button("Done") {
                HapticEngine.shared.success()
                session.navigate(to: .thankYou)
            }
            .buttonStyle(BoothPrimaryButtonStyle(color: .purple))
        }
        .padding(.horizontal, 40)
        .onAppear {
            generateQRCode()
        }
    }

    // MARK: - AirDrop

    private var airdropView: some View {
        VStack(spacing: 24) {
            Image(systemName: "airplayaudio")
                .font(.system(size: 60))
                .foregroundStyle(.cyan)
                .pulsingOpacity()

            Text("AirDrop")
                .font(.title.bold())
                .foregroundStyle(.white)

            Text("Make sure AirDrop is enabled on your device and look for the transfer request.")
                .font(.body)
                .foregroundStyle(.white.opacity(0.7))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)

            if isProcessing {
                ProgressView("Sending...")
                    .tint(.white)
                    .foregroundStyle(.white)
            } else {
                Button("Send via AirDrop") {
                    startAirDrop()
                }
                .buttonStyle(BoothPrimaryButtonStyle(color: .cyan))
            }
        }
        .padding(.horizontal, 40)
    }

    // MARK: - Print

    private var printView: some View {
        VStack(spacing: 24) {
            Image(systemName: "printer.fill")
                .font(.system(size: 60))
                .foregroundStyle(.orange)

            Text("Print Your Photos")
                .font(.title.bold())
                .foregroundStyle(.white)

            Text("Your photos will be sent to the printer. Please collect them from the print station.")
                .font(.body)
                .foregroundStyle(.white.opacity(0.7))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)

            if isProcessing {
                VStack(spacing: 12) {
                    ProgressView()
                        .tint(.white)
                        .scaleEffect(1.5)
                    Text("Printing...")
                        .foregroundStyle(.white.opacity(0.7))
                }
            } else if showSuccess {
                VStack(spacing: 12) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 50))
                        .foregroundStyle(.green)
                    Text("Sent to printer!")
                        .font(.title3.bold())
                        .foregroundStyle(.green)
                }
            } else {
                Button("Print Now") {
                    startPrint()
                }
                .buttonStyle(BoothPrimaryButtonStyle(color: .orange))
            }

            Button("Done") {
                session.navigate(to: .thankYou)
            }
            .buttonStyle(BoothSecondaryButtonStyle())
        }
        .padding(.horizontal, 40)
    }

    // MARK: - Actions

    private func selectOption(_ option: SharingOption) {
        HapticEngine.shared.buttonPress()
        SoundManager.shared.play(.tap)
        selectedOption = option
    }

    private func submitEmail() {
        isProcessing = true
        HapticEngine.shared.buttonPress()
        // In production, call your API to send the email.
        Task {
            try? await Task.sleep(for: .seconds(2))
            isProcessing = false
            showSuccess = true
            HapticEngine.shared.success()
            SoundManager.shared.play(.success)
            try? await Task.sleep(for: .seconds(1.5))
            session.navigate(to: .thankYou)
        }
    }

    private func submitSMS() {
        isProcessing = true
        HapticEngine.shared.buttonPress()
        Task {
            try? await Task.sleep(for: .seconds(2))
            isProcessing = false
            showSuccess = true
            HapticEngine.shared.success()
            SoundManager.shared.play(.success)
            try? await Task.sleep(for: .seconds(1.5))
            session.navigate(to: .thankYou)
        }
    }

    private func generateQRCode() {
        guard let baseURL = session.config.galleryBaseURL else { return }
        // In production, this would include a session-specific gallery token.
        let urlString = baseURL.absoluteString + "/session/\(UUID().uuidString)"

        let context = CIContext()
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(urlString.utf8)
        filter.correctionLevel = "M"

        guard let ciImage = filter.outputImage else { return }
        let transform = CGAffineTransform(scaleX: 10, y: 10)
        let scaledImage = ciImage.transformed(by: transform)

        guard let cgImage = context.createCGImage(scaledImage, from: scaledImage.extent) else { return }

        withAnimation(.spring(response: 0.5)) {
            qrCodeImage = UIImage(cgImage: cgImage)
        }
    }

    private func startAirDrop() {
        isProcessing = true
        // In production, present UIActivityViewController with the captured images.
        Task {
            try? await Task.sleep(for: .seconds(3))
            isProcessing = false
            HapticEngine.shared.success()
            session.navigate(to: .thankYou)
        }
    }

    private func startPrint() {
        isProcessing = true
        HapticEngine.shared.buttonPress()
        // In production, send to the print queue via the Printing pipeline.
        Task {
            try? await Task.sleep(for: .seconds(3))
            isProcessing = false
            showSuccess = true
            HapticEngine.shared.success()
            SoundManager.shared.play(.success)
        }
    }
}

// MARK: - Sharing Option Card

/// A single sharing option in the grid with branded icon and label.
struct SharingOptionCard: View {
    let option: SharingOption
    let action: () -> Void

    @State private var isPressed = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 14) {
                ZStack {
                    Circle()
                        .fill(option.brandColor.opacity(0.2))
                        .frame(width: 80, height: 80)

                    Image(systemName: option.systemIcon)
                        .font(.system(size: 32))
                        .foregroundStyle(option.brandColor)
                }

                Text(option.displayName)
                    .font(.headline)
                    .foregroundStyle(.white)
            }
            .padding(20)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(Color.white.opacity(0.08))
            )
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("Share via \(option.displayName)"))
        .accessibilityAddTraits(.isButton)
    }
}

// MARK: - Custom Text Field Style

/// Dark-themed text field style for the sharing inputs.
struct BoothTextFieldStyle: TextFieldStyle {
    func _body(configuration: TextField<Self._Label>) -> some View {
        configuration
            .font(.title2)
            .foregroundStyle(.white)
            .padding(20)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.white.opacity(0.1))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.2), lineWidth: 1)
                    )
            )
            .tint(.white)
    }
}

#if DEBUG
#Preview("Sharing Screen") {
    let session = BoothSession()
    SharingScreen(session: session)
}
#endif
