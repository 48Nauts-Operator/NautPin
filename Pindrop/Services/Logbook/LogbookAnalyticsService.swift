//
//  LogbookAnalyticsService.swift
//  Pindrop
//
//  Created on 2026-05-17.
//
//  Pure-Swift analytics over TranscriptionRecord history. Produces
//  LogbookSummary for the Logbook UI to render. No network calls.
//  Topic-cluster analysis lives in LogbookTopicAnalyzer.
//

import Foundation

// MARK: - Public data structures

struct LogbookSummary {
    let totalRecords: Int
    let lifetimeWords: Int
    let wordsToday: Int
    let wordsThisWeek: Int
    let sessionsToday: Int
    let sessionsThisWeek: Int
    let averageWPM: Double
    let medianWPM: Double
    let currentStreak: Int
    let longestStreak: Int
    let vocabularyDiversity: Double
    let cleanupRate: Double
    let timeOfDayHistogram: [Int]
    let topTargetApps: [LogbookTargetAppShare]
    let sourceKindBreakdown: [LogbookSourceShare]
    let stress: LogbookStressSignals
    let register: LogbookLanguageRegister
    let habits: LogbookSpeakingHabits
    let hasEnoughData: Bool

    static let empty = LogbookSummary(
        totalRecords: 0, lifetimeWords: 0, wordsToday: 0, wordsThisWeek: 0,
        sessionsToday: 0, sessionsThisWeek: 0,
        averageWPM: 0, medianWPM: 0, currentStreak: 0, longestStreak: 0,
        vocabularyDiversity: 0, cleanupRate: 0,
        timeOfDayHistogram: Array(repeating: 0, count: 24),
        topTargetApps: [], sourceKindBreakdown: [],
        stress: LogbookStressSignals(baselineSampleCount: 0,
                                     baselineFillerRatio: 0,
                                     baselineAvgSentenceLength: 0,
                                     baselineExclamationDensity: 0,
                                     todayFillerRatio: 0,
                                     todayAvgSentenceLength: 0,
                                     todayExclamationDensity: 0,
                                     stressScore: 0,
                                     alert: nil),
        register: LogbookLanguageRegister(politeCount: 0, neutralCount: 0, swearyCount: 0, totalWords: 0),
        habits: LogbookSpeakingHabits(topUnigrams: [], topPhrases: [], topSentenceOpeners: [],
                                      totalSentences: 0, questionSentences: 0,
                                      dayOfWeekHistogram: Array(repeating: 0, count: 7)),
        hasEnoughData: false
    )
}

struct LogbookLanguageRegister {
    let politeCount: Int
    let neutralCount: Int
    let swearyCount: Int
    let totalWords: Int

    var politeRatio: Double {
        totalWords > 0 ? Double(politeCount) / Double(totalWords) : 0
    }
    var swearyRatio: Double {
        totalWords > 0 ? Double(swearyCount) / Double(totalWords) : 0
    }
    var neutralRatio: Double {
        totalWords > 0 ? Double(neutralCount) / Double(totalWords) : 0
    }
}

struct LogbookWordCount: Identifiable {
    let phrase: String
    let count: Int
    var id: String { phrase }
}

struct LogbookSpeakingHabits {
    let topUnigrams: [LogbookWordCount]
    let topPhrases: [LogbookWordCount]      // 2-3 word combos
    let topSentenceOpeners: [LogbookWordCount]
    let totalSentences: Int
    let questionSentences: Int
    let dayOfWeekHistogram: [Int]            // 7 buckets, 0 = Monday

    var questionRate: Double {
        totalSentences > 0 ? Double(questionSentences) / Double(totalSentences) : 0
    }
}

struct LogbookTargetAppShare: Identifiable {
    var id: String { displayName }
    let displayName: String
    let recordCount: Int
    let wordCount: Int
}

struct LogbookSourceShare: Identifiable {
    var id: String { kindRawValue }
    let kindRawValue: String
    let count: Int
}

struct LogbookStressSignals {
    let baselineSampleCount: Int
    let baselineFillerRatio: Double
    let baselineAvgSentenceLength: Double
    let baselineExclamationDensity: Double
    let todayFillerRatio: Double
    let todayAvgSentenceLength: Double
    let todayExclamationDensity: Double
    let stressScore: Double
    let alert: String?
}

// MARK: - Service

@MainActor
final class LogbookAnalyticsService {
    private let historyStore: HistoryStore

    init(historyStore: HistoryStore) {
        self.historyStore = historyStore
    }

    func compute() -> LogbookSummary {
        let records = (try? historyStore.fetchAll()) ?? []
        return Self.compute(from: records, now: Date())
    }

    /// Pure function — testable, no I/O. All inputs explicit.
    static func compute(from records: [TranscriptionRecord], now: Date) -> LogbookSummary {
        guard !records.isEmpty else { return .empty }

        let cal = Calendar.current
        let todayStart = cal.startOfDay(for: now)
        let weekStart = cal.date(byAdding: .day, value: -6, to: todayStart) ?? todayStart
        let last30Start = cal.date(byAdding: .day, value: -29, to: todayStart) ?? todayStart
        let last14Start = cal.date(byAdding: .day, value: -13, to: todayStart) ?? todayStart

        let todayRecords = records.filter { $0.timestamp >= todayStart }
        let weekRecords = records.filter { $0.timestamp >= weekStart }
        let last30Records = records.filter { $0.timestamp >= last30Start }
        let last14Records = records.filter { $0.timestamp >= last14Start }

        let lifetimeWords = records.reduce(0) { $0 + wordCount($1.text) }
        let wordsToday = todayRecords.reduce(0) { $0 + wordCount($1.text) }
        let wordsThisWeek = weekRecords.reduce(0) { $0 + wordCount($1.text) }

        let wpms: [Double] = records.compactMap { record in
            guard record.duration > 0.5 else { return nil }
            let words = wordCount(record.text)
            guard words > 0 else { return nil }
            return Double(words) / record.duration * 60.0
        }
        let averageWPM = wpms.isEmpty ? 0 : wpms.reduce(0, +) / Double(wpms.count)
        let medianWPM = median(of: wpms)

        let recordDates = Set(records.map { cal.startOfDay(for: $0.timestamp) })
        let currentStreak = computeCurrentStreak(recordDates: recordDates, today: todayStart, cal: cal)
        let longestStreak = computeLongestStreak(recordDates: recordDates, cal: cal)

        let last30Text = last30Records.map { $0.text }.joined(separator: " ")
        let vocabularyDiversity = computeVocabularyDiversity(last30Text)

        let enhanced = records.filter { $0.wasEnhanced }.count
        let cleanupRate = Double(enhanced) / Double(records.count)

        var hist = Array(repeating: 0, count: 24)
        for r in records {
            let h = cal.component(.hour, from: r.timestamp)
            if h >= 0 && h < 24 { hist[h] += 1 }
        }

        let appGroups: [String: [TranscriptionRecord]] = Dictionary(grouping: records) { record in
            if let name = record.sourceDisplayName, !name.isEmpty { return name }
            return "Direct dictation"
        }
        var appShares: [LogbookTargetAppShare] = []
        for (name, recs) in appGroups {
            let totalWords = recs.reduce(0) { acc, r in acc + wordCount(r.text) }
            appShares.append(LogbookTargetAppShare(displayName: name,
                                                   recordCount: recs.count,
                                                   wordCount: totalWords))
        }
        appShares.sort { $0.recordCount > $1.recordCount }
        let topTargetApps = Array(appShares.prefix(5))

        let kindGroups = Dictionary(grouping: records, by: { $0.sourceKindRawValue ?? "unknown" })
        let sourceKindBreakdown = kindGroups.map { LogbookSourceShare(kindRawValue: $0.key, count: $0.value.count) }
            .sorted { $0.count > $1.count }

        let stress = computeStress(baseline: last14Records, today: todayRecords)
        let register = computeLanguageRegister(records: last30Records)
        let habits = computeHabits(records: records, last30: last30Records, cal: cal)

        return LogbookSummary(
            totalRecords: records.count,
            lifetimeWords: lifetimeWords,
            wordsToday: wordsToday,
            wordsThisWeek: wordsThisWeek,
            sessionsToday: todayRecords.count,
            sessionsThisWeek: weekRecords.count,
            averageWPM: averageWPM,
            medianWPM: medianWPM,
            currentStreak: currentStreak,
            longestStreak: longestStreak,
            vocabularyDiversity: vocabularyDiversity,
            cleanupRate: cleanupRate,
            timeOfDayHistogram: hist,
            topTargetApps: topTargetApps,
            sourceKindBreakdown: sourceKindBreakdown,
            stress: stress,
            register: register,
            habits: habits,
            hasEnoughData: records.count >= 3
        )
    }

    // MARK: - Language register (polite / neutral / sweary)

    private static let politeWords: Set<String> = [
        // English
        "please", "thanks", "thank", "appreciate", "appreciated", "kindly",
        "sorry", "excuse", "pardon", "welcome", "great", "wonderful",
        "lovely", "awesome", "brilliant", "fantastic", "perfect", "amazing",
        "grateful", "cheers",
        // German
        "bitte", "danke", "dankeschön", "vielen", "entschuldigung",
        "entschuldige", "gerne", "schön", "wunderbar", "herrlich",
        "herzlich", "freundlich", "willkommen", "klasse", "super", "toll"
    ]

    private static let swearyWords: Set<String> = [
        // English
        "fuck", "fucking", "fucked", "fucker", "shit", "shitty", "damn",
        "damned", "hell", "crap", "crappy", "ass", "asshole", "bitch",
        "bastard", "bullshit", "goddamn", "piss", "pissed", "screwed",
        "wtf", "bloody", "freaking", "frigging",
        // German
        "scheiße", "scheisse", "scheiss", "verdammt", "verdammte", "mist",
        "arsch", "arschloch", "fick", "ficken", "kacke", "blöd", "bloed",
        "idiot", "drecksack", "verflucht", "scheißkerl"
    ]

    // MARK: - Speaking habits

    private static let stopWords: Set<String> = [
        // English
        "the","a","an","and","or","but","of","to","in","on","at","for","with","by",
        "from","as","is","are","was","were","be","been","being","have","has","had",
        "do","does","did","will","would","could","should","may","might","must","can",
        "this","that","these","those","i","you","he","she","it","we","they","me",
        "him","her","us","them","my","your","his","hers","its","our","their","not",
        "no","yes","so","just","very","too","also","only","than","when","where","why",
        "how","what","who","which","if","because","while","though","all","any","some",
        "more","most","other","such","out","up","down","into","over","about","there",
        "here","then","now","really","actually","im","ive","its","dont","doesnt","cant",
        // German
        "der","die","das","den","dem","des","ein","eine","einen","einem","einer",
        "und","oder","aber","von","zu","in","an","auf","für","mit","bei","aus","nach",
        "ist","sind","war","waren","sein","hat","hatte","haben","wird","kann","ich",
        "du","er","sie","es","wir","ihr","mich","dich","ihn","uns","euch","mein",
        "dein","nicht","kein","ja","so","nur","sehr","auch","dann","wenn","wo","wie",
        "was","wer","welche","weil","während","aber","doch","schon","noch","mal"
    ]

    private static func computeHabits(records: [TranscriptionRecord],
                                      last30: [TranscriptionRecord],
                                      cal: Calendar) -> LogbookSpeakingHabits {
        let texts = last30.map { ($0.originalText ?? $0.text).lowercased() }

        // Tokenize for unigrams and n-grams.
        let allText = texts.joined(separator: " ")
        let tokens = allText
            .split(whereSeparator: { !$0.isLetter && $0 != "'" })
            .map(String.init)

        var unigramCounts: [String: Int] = [:]
        for token in tokens {
            guard token.count >= 3, !stopWords.contains(token) else { continue }
            unigramCounts[token, default: 0] += 1
        }
        let topUnigrams = unigramCounts
            .filter { $0.value >= 2 }
            .sorted { $0.value > $1.value }
            .prefix(10)
            .map { LogbookWordCount(phrase: $0.key, count: $0.value) }

        // Bigrams + trigrams — keep only if at least one token is content.
        var bigramCounts: [String: Int] = [:]
        var trigramCounts: [String: Int] = [:]
        for i in 0..<tokens.count {
            if i + 1 < tokens.count {
                let a = tokens[i], b = tokens[i+1]
                if a.count >= 2, b.count >= 2,
                   !(stopWords.contains(a) && stopWords.contains(b)) {
                    bigramCounts["\(a) \(b)", default: 0] += 1
                }
            }
            if i + 2 < tokens.count {
                let a = tokens[i], b = tokens[i+1], c = tokens[i+2]
                let stopCount = [a, b, c].filter { stopWords.contains($0) }.count
                if a.count >= 2, b.count >= 2, c.count >= 2, stopCount < 3 {
                    trigramCounts["\(a) \(b) \(c)", default: 0] += 1
                }
            }
        }
        let topBigrams = bigramCounts
            .filter { $0.value >= 2 }
            .sorted { $0.value > $1.value }
            .prefix(5)
        let topTrigrams = trigramCounts
            .filter { $0.value >= 2 }
            .sorted { $0.value > $1.value }
            .prefix(3)
        var phrases: [LogbookWordCount] = []
        for entry in topTrigrams {
            phrases.append(LogbookWordCount(phrase: entry.key, count: entry.value))
        }
        for entry in topBigrams {
            phrases.append(LogbookWordCount(phrase: entry.key, count: entry.value))
        }
        if phrases.count > 8 { phrases = Array(phrases.prefix(8)) }

        // Sentence-level: openers + question rate.
        var openerCounts: [String: Int] = [:]
        var totalSentences = 0
        var questionSentences = 0
        for text in texts {
            // Sentences with their terminators preserved so we can detect questions.
            var current = ""
            var collected: [(text: String, terminator: Character)] = []
            for ch in text {
                if ch == "." || ch == "!" || ch == "?" {
                    let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        collected.append((trimmed, ch))
                    }
                    current = ""
                } else {
                    current.append(ch)
                }
            }
            let trailing = current.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trailing.isEmpty {
                collected.append((trailing, "."))
            }

            for (sentence, terminator) in collected {
                totalSentences += 1
                if terminator == "?" { questionSentences += 1 }

                let words = sentence
                    .split(whereSeparator: { !$0.isLetter && $0 != "'" })
                    .map(String.init)
                guard let first = words.first, !first.isEmpty else { continue }
                let opener: String
                if words.count >= 2, words[1].count <= 5 {
                    opener = "\(first) \(words[1])"
                } else {
                    opener = first
                }
                openerCounts[opener, default: 0] += 1
            }
        }

        let topOpeners = openerCounts
            .filter { $0.value >= 2 }
            .sorted { $0.value > $1.value }
            .prefix(5)
            .map { LogbookWordCount(phrase: $0.key, count: $0.value) }

        // Day-of-week histogram (lifetime). 0 = Monday … 6 = Sunday.
        var dowHist = Array(repeating: 0, count: 7)
        for r in records {
            let weekday = cal.component(.weekday, from: r.timestamp) // 1 = Sun .. 7 = Sat
            let idx = (weekday + 5) % 7                              // Mon -> 0 .. Sun -> 6
            dowHist[idx] += 1
        }

        return LogbookSpeakingHabits(
            topUnigrams: Array(topUnigrams),
            topPhrases: phrases,
            topSentenceOpeners: Array(topOpeners),
            totalSentences: totalSentences,
            questionSentences: questionSentences,
            dayOfWeekHistogram: dowHist
        )
    }

    private static func computeLanguageRegister(records: [TranscriptionRecord]) -> LogbookLanguageRegister {
        var polite = 0
        var sweary = 0
        var total = 0
        for r in records {
            let source = r.originalText ?? r.text
            let words = source.lowercased()
                .split(whereSeparator: { !$0.isLetter && $0 != "'" })
                .map(String.init)
            for w in words {
                total += 1
                if politeWords.contains(w) {
                    polite += 1
                } else if swearyWords.contains(w) {
                    sweary += 1
                }
            }
        }
        let neutral = max(0, total - polite - sweary)
        return LogbookLanguageRegister(politeCount: polite,
                                       neutralCount: neutral,
                                       swearyCount: sweary,
                                       totalWords: total)
    }

    // MARK: - Helpers

    private static func wordCount(_ s: String) -> Int {
        s.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
    }

    private static func median(of values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        if sorted.count % 2 == 0 {
            return (sorted[mid - 1] + sorted[mid]) / 2
        }
        return sorted[mid]
    }

    private static func computeCurrentStreak(recordDates: Set<Date>, today: Date, cal: Calendar) -> Int {
        var streak = 0
        var cursor = today
        if !recordDates.contains(cursor),
           let yesterday = cal.date(byAdding: .day, value: -1, to: cursor) {
            cursor = yesterday
        }
        while recordDates.contains(cursor) {
            streak += 1
            guard let prev = cal.date(byAdding: .day, value: -1, to: cursor) else { break }
            cursor = prev
        }
        return streak
    }

    private static func computeLongestStreak(recordDates: Set<Date>, cal: Calendar) -> Int {
        let sorted = recordDates.sorted()
        var longest = 0
        var current = 0
        var prev: Date?
        for d in sorted {
            if let p = prev,
               let next = cal.date(byAdding: .day, value: 1, to: p),
               cal.isDate(next, inSameDayAs: d) {
                current += 1
            } else {
                current = 1
            }
            longest = max(longest, current)
            prev = d
        }
        return longest
    }

    private static func computeVocabularyDiversity(_ text: String) -> Double {
        let words = text.lowercased()
            .split(whereSeparator: { !$0.isLetter && $0 != "'" })
            .map(String.init)
        guard !words.isEmpty else { return 0 }
        let unique = Set(words).count
        return Double(unique) / Double(words.count)
    }

    // MARK: - Stress signals (Layer 3)

    private static let fillerWords: Set<String> = [
        "um", "uh", "uhh", "umm", "er", "ehh", "ehm",
        "like", "kinda", "sorta", "basically", "literally", "actually",
        "äh", "ähm", "halt", "irgendwie", "quasi", "sozusagen", "also"
    ]

    private static func computeStress(baseline: [TranscriptionRecord],
                                      today: [TranscriptionRecord]) -> LogbookStressSignals {
        let baselineText = baseline.map { $0.originalText ?? $0.text }
        let todayText = today.map { $0.originalText ?? $0.text }

        let baseFiller = fillerRatio(baselineText)
        let baseSL = avgSentenceLength(baselineText)
        let baseExcl = exclamationDensity(baselineText)

        let todayFiller = fillerRatio(todayText)
        let todaySL = avgSentenceLength(todayText)
        let todayExcl = exclamationDensity(todayText)

        var score = 0.0
        var reasons: [String] = []

        if baselineText.count >= 5 && !todayText.isEmpty {
            if todayFiller > baseFiller + 0.02 {
                score += min(1.0, (todayFiller - baseFiller) / 0.05)
                reasons.append("more filler words than usual")
            }
            if baseSL > 0 && todaySL < baseSL - 2 {
                score += min(1.0, (baseSL - todaySL) / 8)
                reasons.append("shorter sentences than usual")
            }
            if todayExcl > baseExcl + 0.01 {
                score += min(1.0, (todayExcl - baseExcl) / 0.03)
                reasons.append("more exclamations than usual")
            }
        }
        let clampedScore = min(1.0, score / 3.0)
        let alert: String? = (clampedScore >= 0.5 && !reasons.isEmpty)
            ? "Your speech today shows " + reasons.joined(separator: ", ") + "."
            : nil

        return LogbookStressSignals(
            baselineSampleCount: baselineText.count,
            baselineFillerRatio: baseFiller,
            baselineAvgSentenceLength: baseSL,
            baselineExclamationDensity: baseExcl,
            todayFillerRatio: todayFiller,
            todayAvgSentenceLength: todaySL,
            todayExclamationDensity: todayExcl,
            stressScore: clampedScore,
            alert: alert
        )
    }

    private static func fillerRatio(_ texts: [String]) -> Double {
        let words = texts.joined(separator: " ")
            .lowercased()
            .split(whereSeparator: { !$0.isLetter && $0 != "'" })
            .map(String.init)
        guard !words.isEmpty else { return 0 }
        let fillers = words.filter { fillerWords.contains($0) }.count
        return Double(fillers) / Double(words.count)
    }

    private static func avgSentenceLength(_ texts: [String]) -> Double {
        var sentenceWordCounts: [Int] = []
        for t in texts {
            let sentences = t.split(whereSeparator: { ".!?".contains($0) })
            for s in sentences {
                let w = s.split(whereSeparator: { $0.isWhitespace }).count
                if w > 0 { sentenceWordCounts.append(w) }
            }
        }
        guard !sentenceWordCounts.isEmpty else { return 0 }
        return Double(sentenceWordCounts.reduce(0, +)) / Double(sentenceWordCounts.count)
    }

    private static func exclamationDensity(_ texts: [String]) -> Double {
        let joined = texts.joined(separator: " ")
        guard !joined.isEmpty else { return 0 }
        let excls = joined.filter { $0 == "!" }.count
        return Double(excls) / Double(joined.count) * 100
    }
}
