import Foundation

@main struct DesktopQuotaValidation {
    static func main() {
        var failures = 0
        func check(_ yes: Bool, _ message: String) {
            if !yes { failures += 1; print("FAIL: \(message)") }
        }
        let date = Date(timeIntervalSince1970: 1_790_000_000)
        let cursor = try? DesktopQuotaParser.parse(.cursor, lines: [
            "Cursor Models · Includes Cursor Grok and Composer 7 % used", "Other Models 28 % used",
            "CURRENT PLAN Pro Usage limits reset on 10月29日 ( 30 days left )"
        ], at: date)
        check(cursor?.pools == [.init(name: "Cursor Models", used: 7), .init(name: "Other Models", used: 28)],
              "Cursor keeps its two independent pools instead of inventing a combined allowance")
        check(cursor?.pools.first?.remaining == 93, "Used percentage must be converted to remaining")
        check(cursor?.resetLabel == "约 30 天后重置", "Only source-provided reset information is displayed")
        let cursorCaption = try? DesktopQuotaParser.parse(.cursor, lines: [
            "Cursor Models 7% used", "Other Models 28% used", "Usage limits reset on 10月29日 (30 days left)"
        ], at: date)
        check(cursorCaption?.resetLabel == "约 30 天后重置", "A separately exposed Cursor reset caption must retain its timing")
        let grok = try? DesktopQuotaParser.parse(.grok, lines: ["每周用量 3%"], at: date)
        check(grok?.pools.first?.remaining == 97 && grok?.resetLabel == nil,
              "Grok Bot weekly usage is not SuperGrok and unknown reset is not guessed")
        let grokSettings = try? DesktopQuotaParser.parse(.grok, lines: [
            "每周用量限额 订阅中包含的用量。每周重置。", "每周用量限额：14%", "7 天后重置 14%",
            "按需每月限额 通过 Cursor 计费"
        ], at: date)
        check(grokSettings?.pools.first?.remaining == 86,
              "The real Grok Usage & Billing page must supply remaining weekly allowance")
        check(grokSettings?.resetLabel == "约 7 天后重置",
              "Grok reset timing must come from its own Usage & Billing section")
        let grokSplit = try? DesktopQuotaParser.parse(.grok, lines: ["每周用量限额：14%", "7 天后重置", "14%"], at: date)
        check(grokSplit?.resetLabel == "约 7 天后重置", "AX may expose the reset caption separately from the usage percentage")
        let conflictingGrok = try? DesktopQuotaParser.parse(.grok, lines: [
            "每周用量限额：14%", "7 天后重置 20%"
        ], at: date)
        check(conflictingGrok == nil, "A mismatched loading snapshot must not become a current quota")
        let untouchedDoubao = try? DesktopQuotaParser.parse(.doubao, lines: [
            "当前时段 未消耗 开始使用后计时 近 7 天 未消耗 开始使用后计时"
        ], at: date)
        check(untouchedDoubao?.pools == [.init(name: "当前时段额度", used: 0), .init(name: "近 7 天额度", used: 0)],
              "Doubao's actual unused quota page exposes two independent pools")
        check(untouchedDoubao?.resetLabel == "开始使用后计时",
              "An unstarted Doubao window cannot be assigned an invented reset date")
        let doubaoExpiry = try? DesktopQuotaParser.parse(.doubao, lines: [
            "当前时段 未消耗 开始使用后计时 近 7 天 未消耗 开始使用后计时",
            "个人订阅 加强套餐 赠送时长至10月31日"
        ], at: date)
        check(doubaoExpiry?.expiryLabel == "赠送时长至10月31日",
              "Subscription expiry is preserved separately from unstarted quota reset timing")
        let invalidExpiry = try? DesktopQuotaParser.parse(.doubao, lines: [
            "当前时段额度用量 10%", "个人订阅 加强套餐 赠送时长至13月40日"
        ], at: date)
        check(invalidExpiry?.expiryLabel == nil, "An invalid expiry date cannot become a countdown")
        let doubao = try? DesktopQuotaParser.parse(.doubao, lines: ["当前时段额度用量 10%"], at: date)
        check(doubao?.pools.first?.remaining == 90, "Doubao period used percentage is not remaining")
        for used in [0, 100] {
            let result = try? DesktopQuotaParser.parse(.doubao, lines: ["当前时段额度用量 \(used)%"], at: date)
            check(result?.pools.first?.remaining == 100 - used, "Actual zero and exhausted allowance are both valid")
        }
        for lines in [["本次对话消耗 10%"], ["当前时段额度用量 -1%"], ["当前时段额度用量 101%"],
                      ["当前时段额度用量 10%", "当前时段额度用量 20%"], [], ["额度用完后显示100%"]] {
            check((try? DesktopQuotaParser.parse(.doubao, lines: lines, at: date)) == nil,
                  "Unrelated, malformed, conflicting and missing fields cannot become a real quota")
        }
        check((try? DesktopQuotaParser.parse(.cursor, lines: ["Cursor Models 7% used"], at: date)) == nil,
              "A partially loaded Cursor plan must not fabricate the other pool")
        let duplicate = try? DesktopQuotaParser.parse(.grok, lines: ["每周用量 3%", "每周用量 3%"], at: date)
        check(duplicate?.pools.first?.used == 3, "Duplicate accessibility attributes may represent the same field")
        check(DesktopQuotaProvider.grok.bundleID == "com.anysphere.sand", "Grok Bot must target the installed Cursor-billed app")
        guard failures == 0 else { exit(1) }
        print("PASS: desktop memberships, pool semantics, reset source, invalid/ambiguous page rejection")
    }
}
