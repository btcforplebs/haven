import SwiftUI

/// One confirmation treatment for every action that cannot be undone.
///
/// Six places in the app fired an irreversible action on a single click — two
/// of them spending money — and the two that did ask never said how much was
/// at stake. Rather than six bespoke alerts that each phrase the stakes
/// differently, every site funnels through this modifier, which fixes the
/// shape of the question:
///
/// - the **title** names the action, in the same words as the button that
///   opened it, so you can tell which control you actually hit;
/// - the **consequence** is one plain sentence about what you lose, and it
///   carries the amount whenever money moves;
/// - **Cancel is the default key action**, so Return and Escape both back out.
///   The destructive verb has to be chosen deliberately, with the pointer.
private struct DestructiveConfirmation: ViewModifier {
    let title: String
    @Binding var isPresented: Bool
    let consequence: String
    let confirmTitle: String
    let cancelTitle: String
    let action: () -> Void

    func body(content: Content) -> some View {
        content.alert(title, isPresented: $isPresented) {
            // Listed first and given the default key action so a stray Return
            // dismisses instead of confirming. `.cancel` already claims Escape.
            Button(cancelTitle, role: .cancel) {}
                .keyboardShortcut(.defaultAction)
            Button(confirmTitle, role: .destructive, action: action)
        } message: {
            Text(consequence)
        }
    }
}

/// The same treatment for a row action, where the confirmation has to name the
/// row it came from — which member, which token, how many sats.
private struct DestructiveItemConfirmation<Item: Identifiable>: ViewModifier {
    let title: String
    @Binding var item: Item?
    let consequence: (Item) -> String
    let confirmTitle: String
    let cancelTitle: String
    let action: (Item) -> Void

    /// `alert(_:isPresented:presenting:)` needs a `Bool` binding of its own;
    /// clearing it has to clear the item too, or the next row opens on the
    /// stale one.
    private var isPresented: Binding<Bool> {
        Binding(
            get: { item != nil },
            set: { if !$0 { item = nil } }
        )
    }

    func body(content: Content) -> some View {
        content.alert(title, isPresented: isPresented, presenting: item) { pending in
            Button(cancelTitle, role: .cancel) {}
                .keyboardShortcut(.defaultAction)
            Button(confirmTitle, role: .destructive) { action(pending) }
        } message: { pending in
            Text(consequence(pending))
        }
    }
}

extension View {
    /// Ask before an action that cannot be undone.
    ///
    /// - Parameters:
    ///   - title: The action, in the same words as the button that opened this.
    ///   - isPresented: Set by that button.
    ///   - consequence: What is lost, in plain words. Name the amount when
    ///     money moves — a confirmation without the number is not one.
    ///   - confirmTitle: The destructive verb. Not "OK".
    ///   - action: Runs only on confirm.
    func confirmDestructive(
        _ title: String,
        isPresented: Binding<Bool>,
        consequence: String,
        confirmTitle: String,
        cancelTitle: String = "Cancel",
        action: @escaping () -> Void
    ) -> some View {
        modifier(DestructiveConfirmation(
            title: title,
            isPresented: isPresented,
            consequence: consequence,
            confirmTitle: confirmTitle,
            cancelTitle: cancelTitle,
            action: action
        ))
    }

    /// Ask before a row action that cannot be undone, naming the row.
    ///
    /// - Parameters:
    ///   - item: The pending row. Non-nil presents the alert; confirming or
    ///     cancelling clears it.
    ///   - consequence: Built from the row, so it can name the member or the
    ///     amount.
    func confirmDestructive<Item: Identifiable>(
        _ title: String,
        item: Binding<Item?>,
        consequence: @escaping (Item) -> String,
        confirmTitle: String,
        cancelTitle: String = "Cancel",
        action: @escaping (Item) -> Void
    ) -> some View {
        modifier(DestructiveItemConfirmation(
            title: title,
            item: item,
            consequence: consequence,
            confirmTitle: confirmTitle,
            cancelTitle: cancelTitle,
            action: action
        ))
    }
}
