import Foundation
import Testing
@testable import NotchBot

@Test func onlyRecognizedLegacyPrivacyPoliciesAreRemovable() {
    #expect(LegacyIntegrationPrivacyPolicy.recognizes(
        Data("{\"version\":1,\"assistantExcerptsEnabled\":true}".utf8)
    ))
    #expect(!LegacyIntegrationPrivacyPolicy.recognizes(
        Data("{\"assistantExcerptsEnabled\":true}".utf8)
    ))
    #expect(!LegacyIntegrationPrivacyPolicy.recognizes(
        Data("{\"version\":1,\"assistantExcerptsEnabled\":true,\"unrelated\":true}".utf8)
    ))
    #expect(!LegacyIntegrationPrivacyPolicy.recognizes(
        Data("{\"version\":1,\"assistantExcerptsEnabled\":1}".utf8)
    ))
    #expect(!LegacyIntegrationPrivacyPolicy.recognizes(
        Data("{\"version\":true,\"assistantExcerptsEnabled\":true}".utf8)
    ))
}
