import SwiftUI
import CoreImage.CIFilterBuiltins

enum SignInMethod: Equatable {
    case password
    case deviceCode(URL)
    case token

    static func methods(for request: SignInRequest) -> [SignInMethod] {
        switch request.challenge?.scheme {
        case "basic", "digest": return [.password]
        case "bearer": return request.challenge?.resourceMetadata.map { [.deviceCode($0), .token] } ?? [.token]
        default: return [.token]
        }
    }
}

struct SignInView: View {
    let request: SignInRequest
    var settingsStore: SettingsStore
    var onDone: () -> Void

    @State private var user = ""
    @State private var password = ""
    @State private var token = ""

    var body: some View {
        VStack(spacing: 28) {
            Text("Sign in to \(request.origin.host)").font(.title2)
            if let realm = request.challenge?.realm { Text(realm).foregroundStyle(.secondary) }
            if request.rejected { Text("The server refused these credentials.").foregroundStyle(.red) }
            ForEach(SignInMethod.methods(for: request), id: \.self) { method in
                switch method {
                case .password:
                    TextField("Username", text: $user).autocorrectionDisabled()
                    SecureField("Password", text: $password)
                    Button("Sign In") { save(.password(user: user, password: password)) }
                        .disabled(user.isEmpty)
                case .deviceCode(let metadata):
                    DeviceCodeView(resourceMetadata: metadata, origin: request.origin) { save(.bearer($0)) }
                case .token:
                    SecureField("Access token", text: $token)
                    Button("Use Token") { save(.bearer(token.trimmingCharacters(in: .whitespaces))) }
                        .disabled(token.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .frame(maxWidth: 900)
        .padding(48)
    }

    private func save(_ credential: Credential) {
        settingsStore.credentials.set(credential, for: request.origin)
        onDone()
    }
}

extension SignInMethod: Hashable {}

struct DeviceCodeView: View {
    let resourceMetadata: URL
    let origin: Origin
    let onToken: (String) -> Void

    @State private var authorization: DeviceAuthorization?
    @State private var failure: String?
    @State private var attempt = 0

    var body: some View {
        VStack(spacing: 20) {
            if let a = authorization {
                Text("On your phone or computer, go to")
                Text(a.verificationURI.absoluteString).font(.title3)
                Text(a.userCode).font(.system(size: 64, weight: .bold, design: .monospaced))
                if let qr = (a.verificationURIComplete ?? a.verificationURI).qrImage {
                    Image(decorative: qr, scale: 1).interpolation(.none).resizable().frame(width: 240, height: 240)
                }
            } else if let failure {
                Text(failure).foregroundStyle(.red)
                Button("Get a New Code") { self.failure = nil; authorization = nil; attempt += 1 }
            } else {
                ProgressView()
            }
        }
        .task(id: attempt) {
            let grant = DeviceGrant()
            do {
                let ep = try await grant.endpoints(resourceMetadata: resourceMetadata, for: origin)
                let a = try await grant.start(ep.device)
                authorization = a
                onToken(try await grant.poll(ep.token, a))
            } catch DeviceGrantError.denied {
                failure = "Sign-in was declined."
            } catch DeviceGrantError.expired {
                failure = "The code expired. Open this screen again for a new one."
            } catch is CancellationError {
            } catch {
                failure = "This server's sign-in could not be started."
            }
        }
    }
}

private extension URL {
    var qrImage: CGImage? {
        let f = CIFilter.qrCodeGenerator()
        f.message = Data(absoluteString.utf8)
        guard let out = f.outputImage else { return nil }
        return CIContext().createCGImage(out, from: out.extent)
    }
}
