// Intentionally empty.
//
// Xcode generates a ControlWidget stub in every Widget Extension template,
// but Control widgets are iOS 18+ and we deploy at iOS 16.1. Keeping the
// file (so Xcode's project references stay intact) but emptying its body
// means the target builds on any iOS 16.1+ device without dragging in
// the iOS-18 API surface. The Bundle in this directory does not register
// any control widget, so removing the implementation has no behaviour cost.
import Foundation
