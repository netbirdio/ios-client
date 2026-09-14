import WidgetKit
import SwiftUI

@main
struct NetBirdWidgetBundle: WidgetBundle {
    var body: some Widget {
        NetBirdWidget()
        if #available(iOS 18.0, *) {
            NetBirdVPNControl()
        }
    }
}
