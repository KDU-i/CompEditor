// Modified for the unofficial Java/Python semantic fork; see FORK_CHANGES.md.
// SPDX-License-Identifier: Apache-2.0
import SwiftUI

// Compatibility bridge for the pinned upstream checkout's item-based dialogs.
// Uses APIs available before macOS 26, avoiding a macOS 27-only fork.
extension View {
    func forkItemAlert<Item, Actions: View, Message: View>(
        _ title: LocalizedStringResource, item: Binding<Item?>,
        @ViewBuilder actions: (Item) -> Actions,
        @ViewBuilder message: (Item) -> Message
    ) -> some View {
        self.alert(String(localized: title), isPresented: Binding(
            get: { item.wrappedValue != nil },
            set: { if !$0 { item.wrappedValue = nil } }
        ), presenting: item.wrappedValue, actions: actions, message: message)
    }

    func forkItemConfirmation<Item, Actions: View, Message: View>(
        _ title: LocalizedStringResource, item: Binding<Item?>,
        @ViewBuilder actions: (Item) -> Actions,
        @ViewBuilder message: (Item) -> Message
    ) -> some View {
        self.confirmationDialog(String(localized: title), isPresented: Binding(
            get: { item.wrappedValue != nil },
            set: { if !$0 { item.wrappedValue = nil } }
        ), presenting: item.wrappedValue, actions: actions, message: message)
    }
}
