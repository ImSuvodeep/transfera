import UIKit
import Social
import MobileCoreServices
import Photos

class ShareViewController: SLComposeServiceViewController {

    override func isContentValid() -> Bool {
        return true
    }

    override func didSelectPost() {
        if let content = extensionContext!.inputItems[0] as? NSExtensionItem {
            if let contents = content.attachments {
                for (index, attachment) in contents.enumerated() {
                    if attachment.hasItemConformingToTypeIdentifier(kUTTypeImage as String) {
                        attachment.loadItem(forTypeIdentifier: kUTTypeImage as String, options: nil) { [weak self] data, error in
                            guard let self = self else { return }
                            
                            var url: URL?
                            if let dataURL = data as? URL {
                                url = dataURL
                            } else if let imageData = data as? UIImage {
                                // Save image to shared App Group container
                                url = self.saveImageToAppGroup(imageData)
                            }
                            
                            if let finalUrl = url {
                                self.saveToUserDefaults(finalUrl.path)
                                self.redirectToHostApp()
                            }
                        }
                    }
                }
            }
        }
    }

    private func saveImageToAppGroup(_ image: UIImage) -> URL? {
        let fileManager = FileManager.default
        guard let groupURL = fileManager.containerURL(forSecurityApplicationGroupIdentifier: "group.com.transfera.transfera") else {
            return nil
        }
        
        let fileURL = groupURL.appendingPathComponent("shared_image.jpg")
        if let data = image.jpegData(compressionQuality: 0.8) {
            try? data.write(to: fileURL)
            return fileURL
        }
        return nil
    }

    private func saveToUserDefaults(_ path: String) {
        if let userDefaults = UserDefaults(suiteName: "group.com.transfera.transfera") {
            userDefaults.set([path], forKey: "sharing_files")
            userDefaults.synchronize()
        }
    }

    private func redirectToHostApp() {
        let url = URL(string: "transfera://")!
        var responder = self as UIResponder?
        let selectorOpenURL = sel_registerName("openURL:")
        while (responder != nil) {
            if (responder!.responds(to: selectorOpenURL)) {
                responder!.perform(selectorOpenURL, with: url)
                break
            }
            responder = responder!.next
        }
        self.extensionContext!.completeRequest(returningItems: [], completionHandler: nil)
    }

    override func configurationItems() -> [Any]! {
        return []
    }
}
