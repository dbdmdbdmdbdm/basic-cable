#if os(tvOS)
import UIKit

// SwiftUI's tvOS focus engine plays a system click on every focus move.
// UIKit asks each focus environment in the chain for a sound identifier;
// SwiftUI's hosting view doesn't implement the hook, so providing it on
// UIView answers for the whole hierarchy and silences navigation clicks.
extension UIView {
    public func soundIdentifierForFocusUpdate(in context: UIFocusUpdateContext) -> UIFocusSoundIdentifier? {
        UIFocusSoundIdentifier.none
    }
}
#endif
