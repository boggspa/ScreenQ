//
//  BroadcastSetupViewController.swift
//  ScreenQBroadcastExtension
//
//  Optional setup UI shown by ReplayKit before broadcast starts. We keep it
//  minimal — we don't ask for credentials inside the extension; instead the
//  host app stores connection details in App Group UserDefaults and the
//  SampleHandler reads them on broadcastStarted.
//

#if os(iOS)
import UIKit
import ReplayKit

@objc(BroadcastSetupViewController)
final class BroadcastSetupViewController: UIViewController {

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        let title = UILabel()
        title.text = "Screen Q Broadcast"
        title.font = .preferredFont(forTextStyle: .title2)
        title.textAlignment = .center
        title.translatesAutoresizingMaskIntoConstraints = false

        let body = UILabel()
        body.numberOfLines = 0
        body.textAlignment = .center
        body.text = "Screen Q will share this device's screen view-only with the connected host. iOS does not allow remote control, so the viewer cannot tap or type for you."
        body.font = .preferredFont(forTextStyle: .body)
        body.textColor = .secondaryLabel
        body.translatesAutoresizingMaskIntoConstraints = false

        let start = UIButton(type: .system)
        start.setTitle("Start broadcasting", for: .normal)
        start.addTarget(self, action: #selector(userDidFinishSetup), for: .touchUpInside)
        start.translatesAutoresizingMaskIntoConstraints = false

        let cancel = UIButton(type: .system)
        cancel.setTitle("Cancel", for: .normal)
        cancel.addTarget(self, action: #selector(userDidCancelSetup), for: .touchUpInside)
        cancel.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(title)
        view.addSubview(body)
        view.addSubview(start)
        view.addSubview(cancel)

        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 32),
            title.centerXAnchor.constraint(equalTo: view.centerXAnchor),

            body.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 16),
            body.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            body.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),

            start.topAnchor.constraint(equalTo: body.bottomAnchor, constant: 32),
            start.centerXAnchor.constraint(equalTo: view.centerXAnchor),

            cancel.topAnchor.constraint(equalTo: start.bottomAnchor, constant: 12),
            cancel.centerXAnchor.constraint(equalTo: view.centerXAnchor)
        ])
    }

    @objc private func userDidFinishSetup() {
        // Pass anything you want via setupInfo to SampleHandler.broadcastStarted.
        let url = URL(string: "screenq://broadcast/start")!
        extensionContext?.completeRequest(withBroadcast: url, setupInfo: [:])
    }

    @objc private func userDidCancelSetup() {
        extensionContext?.cancelRequest(withError: NSError(domain: "ScreenQBroadcast", code: -1))
    }
}
#endif
