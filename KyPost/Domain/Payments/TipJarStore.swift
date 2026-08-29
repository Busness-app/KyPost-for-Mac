//
//  TipJarStore.swift
//  KyPost
//
//  StoreKit 2 support for one-off tips and the optional monthly supporter
//  subscription. Product prices and availability come from App Store Connect.
//

import Foundation
import Observation
import StoreKit

@MainActor
@Observable
final class TipJarStore {
    enum ProductID {
        static let oneTimeMail = "CupOJoe4Mail"
        static let monthlyFive = "5usdmonth"
        static let monthlyTen = "10dolpermonth"

        static let oneOff = [oneTimeMail]
        static let monthly = [monthlyFive, monthlyTen]
        static let all = oneOff + monthly
    }

    private(set) var products: [Product] = []
    private(set) var isMonthlySupporter = false
    private(set) var isLoading = false
    private(set) var errorMessage: String?

    private var updatesTask: Task<Void, Never>?

    func start() async {
        guard updatesTask == nil else { return }
        updatesTask = Task { [weak self] in
            for await result in Transaction.updates {
                await self?.handle(result)
            }
        }
        await refresh()
    }

    func refresh() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            products = try await Product.products(for: ProductID.all)
                .sorted { ProductID.all.firstIndex(of: $0.id)! < ProductID.all.firstIndex(of: $1.id)! }
            await refreshEntitlements()
        } catch {
            errorMessage = "Support options are temporarily unavailable. Please try again later."
        }
    }

    func purchase(_ product: Product) async {
        errorMessage = nil
        do {
            switch try await product.purchase() {
            case .success(let result): await handle(result)
            case .userCancelled, .pending: break
            @unknown default: break
            }
        } catch {
            errorMessage = "The purchase could not be completed. Please try again."
        }
    }

    private func handle(_ result: VerificationResult<Transaction>) async {
        guard case .verified(let transaction) = result else { return }
        if ProductID.monthly.contains(transaction.productID) {
            isMonthlySupporter = transaction.revocationDate == nil &&
                (transaction.expirationDate ?? .distantFuture) > .now
        }
        await transaction.finish()
    }

    private func refreshEntitlements() async {
        isMonthlySupporter = false
        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result,
                  ProductID.monthly.contains(transaction.productID),
                  transaction.revocationDate == nil,
                  (transaction.expirationDate ?? .distantFuture) > .now else { continue }
            isMonthlySupporter = true
        }
    }
}
