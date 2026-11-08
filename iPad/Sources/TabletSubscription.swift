import Combine
import Foundation
import StoreKit
import UIKit

/// App Store Connect owns pricing, trial availability, and introductory-offer eligibility.
enum TabletSubscriptionConfiguration {
    static let productID = "com.tehrandavis.prose.ipad.monthly"
    static let privacyURL = URL(string: "https://github.com/tehrandavis/prose/privacy.html")
    static let termsURL = URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")
}

struct SubscriptionOffering: Equatable {
    let displayPrice: String
    let trialWeeks: Int?
}

enum SubscriptionAccess: Equatable {
    case checking
    case inactive
    case subscribed(until: Date)
    case gracePeriod(until: Date)
    case billingRetry
    case expired
    case revoked

    func permitsWriting(at date: Date) -> Bool {
        switch self {
        case let .subscribed(until), let .gracePeriod(until): date < until
        default: false
        }
    }

    var expiration: Date? {
        switch self {
        case let .subscribed(until), let .gracePeriod(until): until
        default: nil
        }
    }
}

enum SubscriptionPurchaseResult { case purchased, cancelled, pending }

enum SubscriptionNotice: Equatable {
    case pending
    case restored
    case noPurchases
    case failed(String)
}

@MainActor
protocol TabletPurchaseService: AnyObject {
    func offering() async throws -> SubscriptionOffering
    func entitlement() async throws -> SubscriptionAccess
    func purchase() async throws -> SubscriptionPurchaseResult
    func restore() async throws
    func manage(in scene: UIWindowScene) async throws
    func updates() -> AsyncStream<Void>
}

@MainActor
final class TabletSubscription: ObservableObject {
    @Published private(set) var access: SubscriptionAccess = .checking
    @Published private(set) var offering: SubscriptionOffering?
    @Published private(set) var working = false
    @Published var notice: SubscriptionNotice?
    @Published private(set) var productError: String?
    private let service: any TabletPurchaseService
    private let now: () -> Date
    private var listener: Task<Void, Never>?
    private var expirationTask: Task<Void, Never>?
    private var refreshVersion = 0

    init(service: any TabletPurchaseService = StoreKitTabletPurchases(), now: @escaping () -> Date = Date.init) {
        self.service = service
        self.now = now
    }

    deinit {
        listener?.cancel()
        expirationTask?.cancel()
    }

    var canWrite: Bool {
        access.permitsWriting(at: now())
    }

    func start() async {
        guard listener == nil else {
            return
        }
        let updates = service.updates()
        listener = Task { [weak self] in
            for await _ in updates {
                guard !Task.isCancelled else {
                    return
                }
                await self?.refresh()
            }
        }
        await refresh()
    }

    func refresh() async {
        refreshVersion += 1
        let version = refreshVersion
        // Checking purchases is independent of catalog availability. Existing subscribers
        // keep their verified access even when the App Store cannot return a price.
        do {
            let current = try await service.entitlement()
            guard version == refreshVersion else {
                return
            }
            setAccess(current)
        } catch {
            guard version == refreshVersion else {
                return
            }
            setAccess(.inactive)
            notice = .failed(error.localizedDescription)
        }
        do {
            let product = try await service.offering()
            guard version == refreshVersion else {
                return
            }
            offering = product
            productError = nil
        } catch {
            guard version == refreshVersion else {
                return
            }
            offering = nil
            productError = error.localizedDescription
        }
    }

    func purchase() async {
        guard !working, offering != nil else {
            return
        }
        working = true
        notice = nil
        defer { working = false }
        do {
            switch try await service.purchase() {
            case .purchased: await refresh()
            case .pending: notice = .pending
            case .cancelled: break
            }
        } catch { notice = .failed(error.localizedDescription) }
    }

    func restore() async {
        guard !working else {
            return
        }
        working = true
        notice = nil
        defer { working = false }
        do {
            try await service.restore()
            await refresh()
            if case .failed = notice {
                return
            }
            notice = canWrite ? .restored : .noPurchases
        } catch { notice = .failed(error.localizedDescription) }
    }

    func manage(in scene: UIWindowScene) async {
        guard !working else {
            return
        }
        working = true
        notice = nil
        defer { working = false }
        do {
            try await service.manage(in: scene)
            await refresh()
        } catch { notice = .failed(error.localizedDescription) }
    }

    private func setAccess(_ access: SubscriptionAccess) {
        expirationTask?.cancel()
        self.access = access
        if access.permitsWriting(at: now()), notice == .pending {
            notice = nil
        }
        guard let expiration = access.expiration else {
            return
        }
        let interval = expiration.timeIntervalSince(now())
        guard interval > 0 else {
            self.access = .expired
            return
        }
        expirationTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(interval)) } catch { return }
            guard let self else {
                return
            }
            // Disable writing at the verified deadline before checking for renewal.
            self.access = .expired
            await refresh()
        }
    }
}

@MainActor
final class StoreKitTabletPurchases: TabletPurchaseService {
    private var product: Product?

    func offering() async throws -> SubscriptionOffering {
        let product = try await loadProduct()
        guard let subscription = product.subscription else {
            throw PurchaseError.unavailable
        }
        var trialWeeks: Int?
        if await subscription.isEligibleForIntroOffer,
           let offer = subscription.introductoryOffer,
           offer.paymentMode == .freeTrial,
           offer.period.unit == .week
        {
            trialWeeks = offer.period.value * offer.periodCount
        }
        return SubscriptionOffering(displayPrice: product.displayPrice, trialWeeks: trialWeeks)
    }

    func entitlement() async throws -> SubscriptionAccess {
        for await result in Transaction.currentEntitlements {
            guard result.unsafePayloadValue.productID == TabletSubscriptionConfiguration.productID else {
                continue
            }
            return try await access(for: verified(result), isCurrentEntitlement: true)
        }
        // Expired, refunded, and billing-retry subscriptions are absent from currentEntitlements.
        guard let latest = await Transaction.latest(for: TabletSubscriptionConfiguration.productID) else {
            return .inactive
        }
        return try await access(for: verified(latest), isCurrentEntitlement: false)
    }

    func purchase() async throws -> SubscriptionPurchaseResult {
        let product = try await loadProduct()
        switch try await product.purchase() {
        case let .success(result):
            let transaction = try verified(result)
            guard transaction.productID == TabletSubscriptionConfiguration.productID else {
                throw PurchaseError.verificationFailed
            }
            await transaction.finish()
            return .purchased
        case .userCancelled: return .cancelled
        case .pending: return .pending
        @unknown default: throw PurchaseError.unavailable
        }
    }

    func restore() async throws {
        try await AppStore.sync()
    }

    func manage(in scene: UIWindowScene) async throws {
        try await AppStore.showManageSubscriptions(in: scene)
    }

    func updates() -> AsyncStream<Void> {
        AsyncStream { continuation in
            let task = Task.detached {
                for await result in Transaction.updates {
                    guard !Task.isCancelled else {
                        break
                    }
                    guard result.unsafePayloadValue.productID == TabletSubscriptionConfiguration.productID else {
                        continue
                    }
                    // An unverified update triggers a fresh entitlement check but never grants access.
                    continuation.yield(())
                    if case let .verified(transaction) = result {
                        await transaction.finish()
                    }
                }
                continuation.finish()
            }
            let statusTask = Task.detached {
                for await status in Product.SubscriptionInfo.Status.updates {
                    guard !Task.isCancelled else {
                        break
                    }
                    guard status.transaction.unsafePayloadValue.productID == TabletSubscriptionConfiguration.productID
                    else {
                        continue
                    }
                    continuation.yield(())
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
                statusTask.cancel()
            }
        }
    }

    private func loadProduct() async throws -> Product {
        if let product {
            return product
        }
        guard let product = try await Product.products(for: [TabletSubscriptionConfiguration.productID]).first,
              product.type == .autoRenewable,
              product.subscription?.subscriptionPeriod.unit == .month,
              product.subscription?.subscriptionPeriod.value == 1
        else {
            throw PurchaseError.unavailable
        }
        self.product = product
        return product
    }

    private func access(for transaction: Transaction, isCurrentEntitlement: Bool) async throws -> SubscriptionAccess {
        guard transaction.revocationDate == nil else {
            return .revoked
        }
        guard !transaction.isUpgraded else {
            return .inactive
        }
        if let status = await transaction.subscriptionStatus {
            let current = try verified(status.transaction)
            let renewal = try verified(status.renewalInfo)
            guard current.productID == TabletSubscriptionConfiguration.productID,
                  current.revocationDate == nil, !current.isUpgraded
            else {
                return .revoked
            }
            switch status.state {
            case .subscribed:
                guard let expiration = current.expirationDate else {
                    return .inactive
                }
                return .subscribed(until: expiration)
            case .inGracePeriod:
                guard let expiration = renewal.gracePeriodExpirationDate else {
                    return .billingRetry
                }
                return .gracePeriod(until: expiration)
            case .inBillingRetryPeriod: return .billingRetry
            case .revoked: return .revoked
            default: return .expired
            }
        }
        // Only current entitlements support offline access. A historical transaction can
        // keep its original future date after expiration or revocation in StoreKit.
        guard isCurrentEntitlement else {
            return .expired
        }
        guard let expiration = transaction.expirationDate else {
            return .inactive
        }
        return .subscribed(until: expiration)
    }

    private func verified<T>(_ result: VerificationResult<T>) throws -> T {
        guard case let .verified(value) = result else {
            throw PurchaseError.verificationFailed
        }
        return value
    }

    private enum PurchaseError: LocalizedError {
        case unavailable
        case verificationFailed
        var errorDescription: String? {
            switch self {
            case .unavailable: "The monthly subscription is unavailable. Please try again later."
            case .verificationFailed: "The App Store purchase could not be verified. Please restore purchases or try again."
            }
        }
    }
}
