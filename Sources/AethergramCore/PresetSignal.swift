import Foundation

/// Events every consuming app wants and none should rebuild.
///
/// Names here are canonical to the package; each adapter maps them onto its
/// vendor's wire name, which is what keeps a dashboard built against the old
/// name working after a transport swap.
///
/// The set is small on purpose. A preset earns its place by being
/// domain-neutral — an id plus a category, or a purchase's normalised fields —
/// while anything carrying domain vocabulary (screen names, game events) stays
/// with the consumer.
public enum PresetSignal: String, Sendable, CaseIterable {
    case purchaseCompleted = "purchase.completed"
    case errorOccurred = "error.occurred"
}

/// A completed purchase in vendor-neutral fields.
///
/// Deliberately no USD conversion. The SDK this replaces carried a hardcoded
/// exchange-rate table that falls back to zero for a currency it does not know,
/// so its revenue figure silently under-reports; reproducing that would be
/// hardcoding a value that has a data source. The native amount and its
/// currency code go out intact and conversion happens downstream, where the
/// rate can be current.
public struct PurchaseDetails: Equatable, Sendable {
    // MARK: Lifecycle

    public init(
        productID: String,
        countryCode: String,
        currencyCode: String?,
        isSubscription: Bool,
        price: Double?
    ) {
        self.productID = productID
        self.countryCode = countryCode
        self.currencyCode = currencyCode
        self.isSubscription = isSubscription
        self.price = price
    }

    // MARK: Public

    public let productID: String
    public let countryCode: String
    public let currencyCode: String?
    public let isSubscription: Bool
    /// Native amount in `currencyCode`, not converted. Rides the signal's
    /// `floatValue`, so a dashboard summing it must group by currency.
    public let price: Double?

    public var parameters: [String: String] {
        var parameters: [String: String] = [
            PayloadKey.purchaseType: isSubscription ? "subscription" : "one-time-purchase",
            PayloadKey.purchaseCountryCode: countryCode,
            PayloadKey.purchaseProductID: productID
        ]
        if let currencyCode {
            parameters[PayloadKey.purchaseCurrencyCode] = currencyCode
        }
        return parameters
    }
}
