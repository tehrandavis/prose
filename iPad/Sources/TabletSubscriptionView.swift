import ProseCore
import SwiftUI
import UIKit

func subscriptionText(_ english: String, _ chinese: String) -> String {
    L10n.locale.language.languageCode?.identifier == "zh" ? chinese : english
}

struct TabletSubscriptionView: View {
    @ObservedObject var subscription: TabletSubscription

    var body: some View {
        Form {
            Section {
                Text(subscriptionText("Write with Prose on iPad", "在 iPad 上用 Prose 写作"))
                    .font(.title2)
                Text(subscriptionText(
                    "A subscription includes editing, templates, and live typesetting on iPad.",
                    "订阅可使用 iPad 上的编辑、模板和实时排版功能。",
                ))
                Text(subscriptionText(
                    "Your documents remain yours. You can read, preview, and export them without an active subscription.",
                    "文稿始终属于你。没有有效订阅时，你仍可阅读、预览和导出文稿。",
                )).foregroundStyle(.secondary)
            }
            Section(subscriptionText("Monthly subscription", "月度订阅")) {
                Text(status).accessibilityIdentifier("subscription-status")
                if let offering = subscription.offering {
                    Text(subscriptionText("\(offering.displayPrice) per month", "每月 \(offering.displayPrice)"))
                    if let weeks = offering.trialWeeks {
                        Text(subscriptionText(
                            "\(weeks) weeks free, then \(offering.displayPrice) per month.",
                            "免费试用 \(weeks) 周，之后每月 \(offering.displayPrice)。",
                        )).accessibilityIdentifier("subscription-trial")
                    }
                    if !subscription.canWrite {
                        Button(offering.trialWeeks == nil
                            ? subscriptionText("Subscribe", "订阅")
                            : subscriptionText("Start free trial", "开始免费试用"))
                        {
                            Task { await subscription.purchase() }
                        }.accessibilityIdentifier("subscription-purchase").disabled(subscription.working)
                    }
                } else {
                    if let error = subscription.productError {
                        Text(error).foregroundStyle(.secondary)
                    } else {
                        ProgressView(subscriptionText("Loading subscription…", "正在加载订阅…"))
                    }
                    Button(subscriptionText("Try again", "重试")) { Task { await subscription.refresh() } }
                        .disabled(subscription.working)
                }
                if subscription.working {
                    ProgressView()
                }
                if let notice = subscription.notice {
                    Text(message(for: notice)).foregroundStyle(.secondary)
                }
                Button(subscriptionText("Restore purchases", "恢复购买")) { Task { await subscription.restore() } }
                    .accessibilityIdentifier("subscription-restore").disabled(subscription.working)
                Button(subscriptionText("Manage subscription", "管理订阅")) {
                    guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
                        .first(where: { $0.activationState == .foregroundActive })
                    else {
                        return
                    }
                    Task { await subscription.manage(in: scene) }
                }.accessibilityIdentifier("subscription-manage").disabled(subscription.working)
            }
            Section {
                Text(subscriptionText(
                    "Payment is charged to your Apple Account. Your subscription automatically renews unless you cancel at least 24 hours before the current period ends. Manage or cancel in your App Store account settings. Any unused free-trial portion is forfeited when you purchase a subscription. Free trials are available to eligible Apple Accounts only.",
                    "费用将从 Apple 账户扣除。订阅将自动续订，除非你在当前订阅期结束至少 24 小时前取消。可在 App Store 账户设置中管理或取消订阅。购买订阅后，剩余免费试用期将失效。免费试用仅适用于符合资格的 Apple 账户。",
                )).font(.footnote).foregroundStyle(.secondary)
                if let url = TabletSubscriptionConfiguration.privacyURL {
                    Link(subscriptionText("Privacy policy", "隐私政策"), destination: url)
                }
                if let url = TabletSubscriptionConfiguration.termsURL {
                    Link(subscriptionText("Terms of use", "使用条款"), destination: url)
                }
            }
        }.accessibilityIdentifier("subscription-form").task { await subscription.refresh() }
    }

    private var status: String {
        switch subscription.access {
        case .checking: subscriptionText("Checking purchases…", "正在检查购买记录…")
        case .inactive: subscriptionText("Subscribe to start writing.", "订阅后即可开始写作。")
        case let .subscribed(until): subscriptionText(
                "Writing access until \(until.formatted(date: .abbreviated, time: .omitted)).",
                "写作功能有效期至 \(until.formatted(date: .abbreviated, time: .omitted))。",
            )
        case let .gracePeriod(until): subscriptionText(
                "Update your payment method before \(until.formatted(date: .abbreviated, time: .omitted)) to keep writing.",
                "请在 \(until.formatted(date: .abbreviated, time: .omitted)) 前更新付款方式以继续写作。",
            )
        case .billingRetry: subscriptionText("Update your payment method to resume writing.", "请更新付款方式以恢复写作功能。")
        case .expired: subscriptionText(
                "Your subscription has expired. Your documents are still available.",
                "订阅已到期。你的文稿仍可访问。",
            )
        case .revoked: subscriptionText(
                "This subscription is no longer active. Your documents are still available.",
                "此订阅已失效。你的文稿仍可访问。",
            )
        }
    }

    private func message(for notice: SubscriptionNotice) -> String {
        switch notice {
        case .pending: subscriptionText(
                "Your purchase is awaiting approval. Writing unlocks when it is approved.",
                "购买正在等待批准。批准后将解锁写作功能。",
            )
        case .restored: subscriptionText("Your subscription has been restored.", "订阅已恢复。")
        case .noPurchases: subscriptionText(
                "No active subscription was found for this Apple Account.",
                "此 Apple 账户没有有效订阅。",
            )
        case let .failed(message): message
        }
    }
}
