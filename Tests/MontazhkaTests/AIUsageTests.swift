import Testing

@testable import MontazhkaKit

struct AIUsageTests {
    @Test
    func testSumKeepsTokensAndPriceTogether() {
        let first = AIUsage(requests: 1, promptTokens: 100, completionTokens: 20, cost: 0.001)
        let second = AIUsage(requests: 2, promptTokens: 50, completionTokens: 10, cost: 0.0005)

        let total = first + second

        #expect((total.requests) == (3))
        #expect((total.totalTokens) == (180))
        #expect((total.cost.map { ($0 * 10000).rounded() }) == (15))
    }

    @Test
    func testSumSurvivesResponseWithoutPrice() {
        let priced = AIUsage(requests: 1, promptTokens: 10, completionTokens: 1, cost: 0.002)
        let free = AIUsage(requests: 1, promptTokens: 5, completionTokens: 1, cost: nil)

        #expect(((priced + free).cost.map { ($0 * 1000).rounded() }) == (2))
        #expect(((free + priced).cost.map { ($0 * 1000).rounded() }) == (2))
        #expect(((free + free).cost) == (nil))
    }

    @Test
    func testSummaryShowsPriceAndTokensOnlyWhenThereWereRequests() {
        #expect((AIUsage.empty.summary) == (nil))

        let cheap = AIUsage(requests: 4, promptTokens: 14_000, completionTokens: 200, cost: 0.00423)
        let summary = try! #require(cheap.summary)
        #expect(summary.hasPrefix("$0,0042 · 14"))
        #expect(summary.hasSuffix("200 токенов"))

        let expensive = AIUsage(requests: 1, promptTokens: 1, completionTokens: 0, cost: 1.5)
        #expect((expensive.summary) == ("$1,50 · 1 токен"))

        let unpriced = AIUsage(requests: 1, promptTokens: 2, completionTokens: 1, cost: nil)
        #expect((unpriced.summary) == ("3 токена"))
    }
}
