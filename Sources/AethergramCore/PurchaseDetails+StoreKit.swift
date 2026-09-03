#if canImport(StoreKit)
    import Foundation
    import StoreKit

    public extension PurchaseDetails {
        /// Normalises a StoreKit transaction into the preset's fields.
        ///
        /// StoreKit is a system framework rather than a dependency, so this
        /// belongs in the package: every app selling in-app purchases wants the
        /// same four fields, and rebuilding them per app is how they drift.
        init(transaction: StoreKit.Transaction) {
            self.init(
                productID: transaction.productID,
                countryCode: transaction.storefront.countryCode,
                currencyCode: transaction.currency?.identifier,
                isSubscription: transaction.subscriptionGroupID != nil,
                price: transaction.price.map { NSDecimalNumber(decimal: $0).doubleValue }
            )
        }
    }
#endif
