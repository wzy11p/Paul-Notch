import Foundation

/// China-site pay-as-you-go wallet, not Token Plan quota or Audio membership credits.
/// Contract: MiniMax-AI/cli AccountBalanceResponse + /account/query_balance.
struct MiniMaxWalletBalance: Sendable {
    let available, cash, voucher, credit, owed: Decimal
    let observedAt: Date

    static func decode(_ data: Data, at date: Date) throws -> Self {
        struct Status: Decodable { let status_code: Int }
        struct Envelope: Decodable { let base_resp: Status }
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data) else {
            throw QuotaConnectionError.invalidData
        }
        if envelope.base_resp.status_code == 1004 { throw QuotaConnectionError.authentication }
        guard envelope.base_resp.status_code == 0 else { throw QuotaConnectionError.unavailable }
        struct Payload: Decodable {
            let available_amount, cash_balance, voucher_balance, credit_balance, owed_amount: String
        }
        guard let payload = try? JSONDecoder().decode(Payload.self, from: data) else {
            throw QuotaConnectionError.invalidData
        }
        func amount(_ text: String) throws -> Decimal {
            guard text.count <= 40, text.range(of: #"^-?[0-9]+(?:\.[0-9]+)?$"#, options: .regularExpression) != nil,
                  let value = Decimal(string: text, locale: Locale(identifier: "en_US_POSIX")), !value.isNaN else {
                throw QuotaConnectionError.invalidData
            }
            return value
        }
        return try Self(available: amount(payload.available_amount), cash: amount(payload.cash_balance),
                        voucher: amount(payload.voucher_balance), credit: amount(payload.credit_balance),
                        owed: amount(payload.owed_amount), observedAt: date)
    }
}
