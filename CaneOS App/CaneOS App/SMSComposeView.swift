import SwiftUI
import MessageUI

/// One SOS's worth of pre-filled Messages content.
struct SMSCompose: Identifiable {
    let id = UUID()
    let recipients: [String]
    let body: String
}

/// Wraps the system Messages compose sheet. iOS deliberately forbids apps
/// from sending SMS silently, so this is as close as any app can get to
/// automatic: everything pre-filled, one tap on Send delivers a real SMS
/// from the user's own number. (The Resend email → carrier-gateway path
/// runs in parallel as the zero-touch layer.)
struct SMSComposeView: UIViewControllerRepresentable {
    let compose: SMSCompose
    let onDismiss: () -> Void

    static var canSend: Bool { MFMessageComposeViewController.canSendText() }

    func makeCoordinator() -> Coordinator { Coordinator(onDismiss: onDismiss) }

    func makeUIViewController(context: Context) -> MFMessageComposeViewController {
        let controller = MFMessageComposeViewController()
        controller.recipients = compose.recipients
        controller.body = compose.body
        controller.messageComposeDelegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: MFMessageComposeViewController, context: Context) {}

    final class Coordinator: NSObject, MFMessageComposeViewControllerDelegate {
        let onDismiss: () -> Void
        init(onDismiss: @escaping () -> Void) { self.onDismiss = onDismiss }

        func messageComposeViewController(_ controller: MFMessageComposeViewController,
                                          didFinishWith result: MessageComposeResult) {
            onDismiss()
        }
    }
}
