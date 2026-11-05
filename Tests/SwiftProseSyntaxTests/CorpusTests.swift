import Foundation
import Testing
@testable import SwiftProseSyntax
import SwiftProseTestSupport

extension CorpusSample: CustomTestStringConvertible {}

@Suite("Corpus golden")
struct CorpusGoldenTests {
    @Test(arguments: CorpusFixtures.bugzilla + CorpusFixtures.phabricator)
    func bugzillaAndPhabricatorSamples(_ sample: CorpusSample) {
        #expect(Corpus.roundTrip(sample.source) == sample.expected)
    }

    @Test(arguments: CorpusFixtures.remarkupDrafts)
    func remarkupDraftsSurviveWithoutLabels(_ sample: CorpusSample) {
        #expect(Corpus.roundTrip(sample.source) == sample.expected)
    }

    @Test(arguments: CorpusFixtures.remarkupDrafts)
    func remarkupDraftsSurviveWithLabels(_ sample: CorpusSample) {
        #expect(Corpus.roundTrip(sample.source, labels: true) == sample.expected)
    }

    @Test(arguments: CorpusFixtures.canonicalizing)
    func canonicalizingSamples(_ sample: CorpusSample) {
        #expect(Corpus.roundTrip(sample.source) == sample.expected)
    }

    @Test func canonicalizingSamplesAreNotCanonical() {
        for sample in CorpusFixtures.canonicalizing {
            #expect(!sample.isCanonical, "\(sample.name)")
        }
    }

    @Test func labelSourcesAreByteExact() throws {
        let draft = "{nav,  icon=file, name=Ready} and {nav icon=check, name=Accepted}"
        let storage = Corpus.load(draft, labels: true)
        let sources = LoaderFixture.attachments(storage).map(\.markdownSource)
        #expect(sources == ["{nav,  icon=file, name=Ready}", "{nav icon=check, name=Accepted}"])
        #expect(storage.string == "\u{FFFC} and \u{FFFC}")
        #expect(Corpus.write(storage) == draft)
    }

    @Test func remarkupSyntaxStaysPlainText() {
        let storage = Corpus.load("//a// ##b## [[https://example.com | c]]")
        #expect(storage.string == "//a// ##b## [[https://example.com | c]]")
        #expect(LoaderFixture.intentRuns(storage).allSatisfy { $0.1.intersection(.markdownMarks).isEmpty })
        #expect(storage.markdownBlock(at: 0) == .paragraph)
    }
}

@Suite("Corpus properties")
struct CorpusPropertyTests {
    @Test(arguments: CorpusFixtures.canonical)
    func canonicalSamplesAreFixedPoints(_ sample: CorpusSample) {
        #expect(Corpus.roundTrip(sample.source) == sample.source)
    }

    @Test(arguments: CorpusFixtures.canonical)
    func canonicalSamplesAreFixedPointsWithLabels(_ sample: CorpusSample) {
        #expect(Corpus.roundTrip(sample.source, labels: true) == sample.source)
    }

    @Test(arguments: CorpusFixtures.canonicalizing)
    func canonicalizationIsIdempotent(_ sample: CorpusSample) {
        let once = Corpus.roundTrip(sample.source)
        #expect(Corpus.roundTrip(once) == once)
    }

    @Test(arguments: CorpusFixtures.canonical)
    func loadingIsDeterministic(_ sample: CorpusSample) {
        let first = Corpus.load(sample.source)
        let second = Corpus.load(sample.source)
        #expect(first.string == second.string)
        #expect(LoaderFixture.paragraphs(first).map(\.text) == LoaderFixture.paragraphs(second).map(\.text))
        #expect(Corpus.write(first) == Corpus.write(second))
    }

    @Test(arguments: CorpusFixtures.canonical)
    func loadedBlocksAreUniformPerParagraph(_ sample: CorpusSample) {
        let storage = Corpus.load(sample.source)
        #expect(LoaderFixture.blockIsUniform(storage))
    }

    @Test(arguments: CorpusFixtures.canonical)
    func noFallbackRunsInCanonicalSamples(_ sample: CorpusSample) {
        let report = LoaderFixture.load(sample.source).report
        #expect(report.fallbackRuns == 0)
    }

    @Test(arguments: CorpusFixtures.canonical)
    func everyBlockConcatenationIsCanonical(_ sample: CorpusSample) {
        let doubled = sample.source + "\n\n" + sample.source
        let once = Corpus.roundTrip(doubled)
        #expect(Corpus.roundTrip(once) == once)
    }
}
