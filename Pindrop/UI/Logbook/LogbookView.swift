//
//  LogbookView.swift
//  Pindrop
//
//  Created on 2026-05-17.
//
//  Personal voice-stats dashboard. Three sections:
//    1. Quantitative cards (words, WPM, streaks, splits, time-of-day)
//    2. Topic clusters from local LLM (Where your knowledge has been)
//    3. Wellbeing signals (text-based stress detection vs your baseline)
//

import Charts
import SwiftData
import SwiftUI

struct LogbookView: View {
    @Query(sort: \TranscriptionRecord.timestamp, order: .reverse)
    private var records: [TranscriptionRecord]

    @Environment(\.locale) private var locale

    @State private var topicClusters: [LogbookTopicCluster] = []
    @State private var topicError: String?
    @State private var topicErrorHeadline: String = ""
    @State private var isLoadingTopics: Bool = false
    @State private var lastTopicLoad: Date?

    private let topicAnalyzer = LogbookTopicAnalyzer()

    private var summary: LogbookSummary {
        LogbookAnalyticsService.compute(from: records, now: Date())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xl) {
            if !summary.hasEnoughData {
                emptyState
            } else {
                quantitativeSection
                habitsSection
                topicsSection
                wellbeingSection
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task {
            await refreshTopicsIfNeeded()
        }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        SettingsCard(
            title: localized("Logbook", locale: locale),
            icon: "book.pages"
        ) {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
                Text(localized("Your Logbook is empty — keep dictating and patterns will appear here.", locale: locale))
                    .font(AppTypography.body)
                    .foregroundStyle(AppColors.textPrimary)
                Text(localized("Stats unlock once you have a handful of dictations. Word counts, speaking pace, vocabulary, topic clusters from your own local LLM, and a wellbeing signal that flags when your speech patterns drift from your baseline.", locale: locale))
                    .font(AppTypography.caption)
                    .foregroundStyle(AppColors.textSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Layer 1: Quantitative

    private var quantitativeSection: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            sectionHeader(
                title: localized("By the numbers", locale: locale),
                subtitle: localized("Counts and pace from every dictation you've ever made.", locale: locale)
            )

            kpiGrid

            SettingsCard(
                title: localized("Time of day", locale: locale),
                icon: "clock"
            ) {
                timeOfDayHeatmap
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            SettingsCard(
                title: localized("Where you dictate most", locale: locale),
                icon: "macwindow"
            ) {
                targetAppList
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var kpiGrid: some View {
        let columns = [
            GridItem(.flexible(), spacing: AppTheme.Spacing.md),
            GridItem(.flexible(), spacing: AppTheme.Spacing.md),
            GridItem(.flexible(), spacing: AppTheme.Spacing.md)
        ]
        return LazyVGrid(columns: columns, spacing: AppTheme.Spacing.md) {
            kpiCard(title: "Words today",
                    value: formatInt(summary.wordsToday),
                    accent: AppColors.accent)
            kpiCard(title: "Words this week",
                    value: formatInt(summary.wordsThisWeek),
                    accent: AppColors.accent)
            kpiCard(title: "Lifetime words",
                    value: formatInt(summary.lifetimeWords),
                    accent: AppColors.textPrimary)
            kpiCard(title: "Avg WPM",
                    value: formatDouble(summary.averageWPM, digits: 0),
                    accent: AppColors.textPrimary)
            kpiCard(title: "Median WPM",
                    value: formatDouble(summary.medianWPM, digits: 0),
                    accent: AppColors.textSecondary)
            kpiCard(title: "Sessions today",
                    value: "\(summary.sessionsToday)",
                    accent: AppColors.textPrimary)
            kpiCard(title: "Current streak",
                    value: "\(summary.currentStreak)d",
                    accent: AppColors.accent)
            kpiCard(title: "Longest streak",
                    value: "\(summary.longestStreak)d",
                    accent: AppColors.textPrimary)
            kpiCard(title: "Vocab diversity",
                    value: formatPercent(summary.vocabularyDiversity),
                    accent: AppColors.textPrimary)
        }
    }

    private func kpiCard(title: String, value: String, accent: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value)
                .font(AppTypography.statMedium)
                .foregroundStyle(accent)
                .monospacedDigit()
            Text(title)
                .font(AppTypography.caption)
                .foregroundStyle(AppColors.textSecondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, minHeight: 70, alignment: .leading)
        .padding(AppTheme.Spacing.md)
        .background(AppColors.surfaceBackground, in: RoundedRectangle(cornerRadius: AppTheme.Radius.md))
        .overlay(
            RoundedRectangle(cornerRadius: AppTheme.Radius.md)
                .stroke(AppColors.divider, lineWidth: 0.5)
        )
    }

    private var timeOfDayHeatmap: some View {
        let maxCount = max(summary.timeOfDayHistogram.max() ?? 1, 1)
        return VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            HStack(alignment: .bottom, spacing: 4) {
                ForEach(0..<24, id: \.self) { hour in
                    let value = summary.timeOfDayHistogram[hour]
                    let ratio = Double(value) / Double(maxCount)
                    VStack(spacing: 4) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(AppColors.accent.opacity(0.18 + ratio * 0.82))
                            .frame(height: 6 + CGFloat(ratio) * 64)
                        Text("\(hour)")
                            .font(.system(size: 9, weight: .regular, design: .monospaced))
                            .foregroundStyle(AppColors.textTertiary)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            Text(localized("Hour of day (24h) — taller bars mean more dictations.", locale: locale))
                .font(AppTypography.caption)
                .foregroundStyle(AppColors.textSecondary)
        }
    }

    @ViewBuilder
    private var targetAppList: some View {
        if summary.topTargetApps.isEmpty {
            Text(localized("No target-app data yet.", locale: locale))
                .font(AppTypography.caption)
                .foregroundStyle(AppColors.textSecondary)
        } else {
            let maxCount = max(summary.topTargetApps.first?.recordCount ?? 1, 1)
            VStack(spacing: AppTheme.Spacing.sm) {
                ForEach(summary.topTargetApps) { app in
                    HStack(spacing: AppTheme.Spacing.md) {
                        Text(app.displayName)
                            .font(AppTypography.body)
                            .foregroundStyle(AppColors.textPrimary)
                            .frame(width: 160, alignment: .leading)
                            .lineLimit(1)

                        GeometryReader { proxy in
                            let ratio = CGFloat(app.recordCount) / CGFloat(maxCount)
                            ZStack(alignment: .leading) {
                                RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                                    .fill(AppColors.surfaceBackground)
                                RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                                    .fill(AppColors.accent.opacity(0.85))
                                    .frame(width: max(8, proxy.size.width * ratio))
                            }
                        }
                        .frame(height: 16)

                        Text("\(app.recordCount)")
                            .font(AppTypography.caption.monospacedDigit())
                            .foregroundStyle(AppColors.textSecondary)
                            .frame(width: 44, alignment: .trailing)
                    }
                }
            }
        }
    }

    // MARK: - Speaking habits

    private var habitsSection: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            sectionHeader(
                title: localized("Speaking habits", locale: locale),
                subtitle: localized("Words you reach for, how you start sentences, and when in the week you talk most.", locale: locale)
            )

            SettingsCard(
                title: localized("Words and phrases you reach for", locale: locale),
                icon: "text.quote"
            ) {
                petPhrasesBody
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            SettingsCard(
                title: localized("How you frame thoughts", locale: locale),
                icon: "questionmark.bubble"
            ) {
                framingBody
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            SettingsCard(
                title: localized("Day of the week", locale: locale),
                icon: "calendar"
            ) {
                dayOfWeekHeatmap
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @ViewBuilder
    private var petPhrasesBody: some View {
        let h = summary.habits
        if h.topUnigrams.isEmpty && h.topPhrases.isEmpty {
            Text(localized("Not enough words yet to spot patterns.", locale: locale))
                .font(AppTypography.caption)
                .foregroundStyle(AppColors.textSecondary)
        } else {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
                if !h.topUnigrams.isEmpty {
                    VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                        Text(localized("Single words", locale: locale))
                            .font(AppTypography.caption)
                            .foregroundStyle(AppColors.textSecondary)
                        FlowLayout(spacing: AppTheme.Spacing.xs) {
                            ForEach(h.topUnigrams) { w in
                                wordChip(phrase: w.phrase, count: w.count)
                            }
                        }
                    }
                }
                if !h.topPhrases.isEmpty {
                    VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                        Text(localized("Phrases (2-3 words)", locale: locale))
                            .font(AppTypography.caption)
                            .foregroundStyle(AppColors.textSecondary)
                        FlowLayout(spacing: AppTheme.Spacing.xs) {
                            ForEach(h.topPhrases) { p in
                                wordChip(phrase: p.phrase, count: p.count)
                            }
                        }
                    }
                }
                Text(localized("Based on the past 30 days. Stop words filtered out.", locale: locale))
                    .font(AppTypography.caption)
                    .foregroundStyle(AppColors.textTertiary)
            }
        }
    }

    private func wordChip(phrase: String, count: Int) -> some View {
        HStack(spacing: 6) {
            Text(phrase)
                .font(AppTypography.body)
                .foregroundStyle(AppColors.textPrimary)
            Text("\(count)")
                .font(AppTypography.caption.monospacedDigit())
                .foregroundStyle(AppColors.accent)
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(AppColors.surfaceBackground, in: RoundedRectangle(cornerRadius: AppTheme.Radius.sm))
        .overlay(
            RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                .stroke(AppColors.divider, lineWidth: 0.5)
        )
    }

    @ViewBuilder
    private var framingBody: some View {
        let h = summary.habits
        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            HStack(alignment: .top, spacing: AppTheme.Spacing.xl) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(formatPercent(h.questionRate))
                        .font(AppTypography.statMedium)
                        .foregroundStyle(AppColors.accent)
                        .monospacedDigit()
                    Text(localized("of your sentences are questions", locale: locale))
                        .font(AppTypography.caption)
                        .foregroundStyle(AppColors.textSecondary)
                    Text("(\(h.questionSentences) of \(h.totalSentences))")
                        .font(AppTypography.caption.monospacedDigit())
                        .foregroundStyle(AppColors.textTertiary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                    Text(localized("How your sentences begin", locale: locale))
                        .font(AppTypography.caption)
                        .foregroundStyle(AppColors.textSecondary)
                    if h.topSentenceOpeners.isEmpty {
                        Text(localized("Not enough sentences yet.", locale: locale))
                            .font(AppTypography.caption)
                            .foregroundStyle(AppColors.textTertiary)
                    } else {
                        ForEach(h.topSentenceOpeners) { opener in
                            HStack {
                                Text("\u{201C}\(opener.phrase)…\u{201D}")
                                    .font(AppTypography.body)
                                    .foregroundStyle(AppColors.textPrimary)
                                Spacer(minLength: 8)
                                Text("\(opener.count)")
                                    .font(AppTypography.caption.monospacedDigit())
                                    .foregroundStyle(AppColors.textTertiary)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var dayOfWeekHeatmap: some View {
        let h = summary.habits.dayOfWeekHistogram
        let maxCount = max(h.max() ?? 1, 1)
        let labels = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
        return VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            HStack(alignment: .bottom, spacing: AppTheme.Spacing.sm) {
                ForEach(0..<7, id: \.self) { day in
                    let value = h[day]
                    let ratio = Double(value) / Double(maxCount)
                    VStack(spacing: 4) {
                        Text("\(value)")
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundStyle(AppColors.textSecondary)
                            .opacity(value > 0 ? 1 : 0.4)
                        RoundedRectangle(cornerRadius: 4)
                            .fill(AppColors.accent.opacity(0.25 + ratio * 0.75))
                            .frame(height: 10 + CGFloat(ratio) * 70)
                        Text(localized(labels[day], locale: locale))
                            .font(AppTypography.caption)
                            .foregroundStyle(AppColors.textSecondary)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            Text(localized("Dictations per weekday (lifetime).", locale: locale))
                .font(AppTypography.caption)
                .foregroundStyle(AppColors.textTertiary)
        }
    }

    // MARK: - Layer 2: Topic clusters

    private var topicsSection: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            sectionHeader(
                title: localized("Where your knowledge has been", locale: locale),
                subtitle: localized("Topic clusters from this week's dictations, summarized by your local LLM.", locale: locale)
            )

            SettingsCard(
                title: localized("This week's themes", locale: locale),
                icon: "brain"
            ) {
                topicsCardBody
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @ViewBuilder
    private var topicsCardBody: some View {
        if isLoadingTopics {
            HStack(spacing: AppTheme.Spacing.sm) {
                ProgressView().controlSize(.small)
                Text(localized("Asking your local LLM…", locale: locale))
                    .font(AppTypography.caption)
                    .foregroundStyle(AppColors.textSecondary)
            }
        } else if let err = topicError {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                Text(topicErrorHeadline)
                    .font(AppTypography.body)
                    .foregroundStyle(AppColors.textPrimary)
                Text(err)
                    .font(AppTypography.caption)
                    .foregroundStyle(AppColors.textSecondary)
                Button {
                    Task { await refreshTopicsIfNeeded(force: true) }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.clockwise")
                        Text(localized("Retry", locale: locale))
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        } else if topicClusters.isEmpty {
            Text(localized("Not enough recent dictations to find clear themes yet.", locale: locale))
                .font(AppTypography.caption)
                .foregroundStyle(AppColors.textSecondary)
        } else {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
                ForEach(topicClusters) { cluster in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(cluster.title)
                            .font(AppTypography.subheadline)
                            .foregroundStyle(AppColors.accent)
                        Text(cluster.description)
                            .font(AppTypography.body)
                            .foregroundStyle(AppColors.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    if cluster.id != topicClusters.last?.id {
                        Divider().background(AppColors.divider)
                    }
                }
                if let lastTopicLoad {
                    Text(refreshLabel(lastTopicLoad))
                        .font(AppTypography.caption)
                        .foregroundStyle(AppColors.textTertiary)
                }
            }
        }
    }

    private func refreshLabel(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        let rel = formatter.localizedString(for: date, relativeTo: Date())
        return String(format: localized("Generated %@", locale: locale), rel)
    }

    // MARK: - Layer 3: Wellbeing

    private var wellbeingSection: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            sectionHeader(
                title: localized("Wellbeing signals", locale: locale),
                subtitle: localized("How your speech today compares to your 14-day baseline. Text signals only — audio prosody coming next.", locale: locale)
            )

            SettingsCard(
                title: localized("Today vs your baseline", locale: locale),
                icon: "waveform.path.ecg"
            ) {
                wellbeingBody
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            SettingsCard(
                title: localized("How you talk", locale: locale),
                icon: "bubble.left.and.bubble.right"
            ) {
                languageRegisterBody
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @ViewBuilder
    private var languageRegisterBody: some View {
        let r = summary.register
        if r.totalWords < 50 {
            Text(localized("Not enough words analysed yet — keep dictating.", locale: locale))
                .font(AppTypography.caption)
                .foregroundStyle(AppColors.textSecondary)
        } else {
            HStack(alignment: .center, spacing: AppTheme.Spacing.xl) {
                registerDonut(register: r)
                    .frame(width: 160, height: 160)

                VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                    registerLegendRow(swatch: AppColors.success,
                                       label: localized("Polite", locale: locale),
                                       count: r.politeCount,
                                       ratio: r.politeRatio)
                    registerLegendRow(swatch: AppColors.textTertiary.opacity(0.55),
                                       label: localized("Neutral", locale: locale),
                                       count: r.neutralCount,
                                       ratio: r.neutralRatio)
                    registerLegendRow(swatch: AppColors.warning,
                                       label: localized("Sweary", locale: locale),
                                       count: r.swearyCount,
                                       ratio: r.swearyRatio)
                    Text(localized("Based on the past 30 days of dictations.", locale: locale))
                        .font(AppTypography.caption)
                        .foregroundStyle(AppColors.textTertiary)
                        .padding(.top, 4)
                }
                Spacer(minLength: 0)
            }
        }
    }

    private func registerDonut(register r: LogbookLanguageRegister) -> some View {
        Chart {
            SectorMark(
                angle: .value("Polite", r.politeCount),
                innerRadius: .ratio(0.62),
                angularInset: 2
            )
            .cornerRadius(4)
            .foregroundStyle(AppColors.success)

            SectorMark(
                angle: .value("Neutral", r.neutralCount),
                innerRadius: .ratio(0.62),
                angularInset: 2
            )
            .cornerRadius(4)
            .foregroundStyle(AppColors.textTertiary.opacity(0.55))

            SectorMark(
                angle: .value("Sweary", r.swearyCount),
                innerRadius: .ratio(0.62),
                angularInset: 2
            )
            .cornerRadius(4)
            .foregroundStyle(AppColors.warning)
        }
        .chartLegend(.hidden)
    }

    private func registerLegendRow(swatch: Color, label: String, count: Int, ratio: Double) -> some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            RoundedRectangle(cornerRadius: 3)
                .fill(swatch)
                .frame(width: 12, height: 12)
            Text(label)
                .font(AppTypography.body)
                .foregroundStyle(AppColors.textPrimary)
                .frame(width: 70, alignment: .leading)
            Text(formatPercent(ratio))
                .font(AppTypography.body.monospacedDigit())
                .foregroundStyle(AppColors.textPrimary)
                .frame(width: 55, alignment: .trailing)
            Text("(\(count))")
                .font(AppTypography.caption.monospacedDigit())
                .foregroundStyle(AppColors.textTertiary)
        }
    }

    @ViewBuilder
    private var wellbeingBody: some View {
        let s = summary.stress
        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            if let alert = s.alert {
                HStack(alignment: .top, spacing: AppTheme.Spacing.sm) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(AppColors.warning)
                    Text(alert)
                        .font(AppTypography.body)
                        .foregroundStyle(AppColors.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(AppTheme.Spacing.md)
                .background(AppColors.warningBackground, in: RoundedRectangle(cornerRadius: AppTheme.Radius.md))
            } else if s.baselineSampleCount < 5 {
                Text(localized("Building your baseline — need at least 5 dictations from the past two weeks to compare.", locale: locale))
                    .font(AppTypography.caption)
                    .foregroundStyle(AppColors.textSecondary)
            } else {
                Text(localized("Your speech today is in line with your normal patterns.", locale: locale))
                    .font(AppTypography.body)
                    .foregroundStyle(AppColors.textPrimary)
            }

            comparisonRow(label: localized("Filler words", locale: locale),
                          baseline: formatPercent(s.baselineFillerRatio),
                          today: formatPercent(s.todayFillerRatio))
            comparisonRow(label: localized("Avg sentence length", locale: locale),
                          baseline: formatDouble(s.baselineAvgSentenceLength, digits: 1) + " words",
                          today: formatDouble(s.todayAvgSentenceLength, digits: 1) + " words")
            comparisonRow(label: localized("Exclamations (per 100 chars)", locale: locale),
                          baseline: formatDouble(s.baselineExclamationDensity, digits: 2),
                          today: formatDouble(s.todayExclamationDensity, digits: 2))
        }
    }

    private func comparisonRow(label: String, baseline: String, today: String) -> some View {
        HStack(spacing: AppTheme.Spacing.md) {
            Text(label)
                .font(AppTypography.caption)
                .foregroundStyle(AppColors.textSecondary)
                .frame(width: 200, alignment: .leading)
            Text(today)
                .font(AppTypography.body.monospacedDigit())
                .foregroundStyle(AppColors.textPrimary)
                .frame(width: 120, alignment: .leading)
            Text(localized("baseline: ", locale: locale) + baseline)
                .font(AppTypography.caption.monospacedDigit())
                .foregroundStyle(AppColors.textTertiary)
            Spacer(minLength: 0)
        }
    }

    // MARK: - Section header helper

    private func sectionHeader(title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(AppTypography.title)
                .foregroundStyle(AppColors.textPrimary)
            Text(subtitle)
                .font(AppTypography.body)
                .foregroundStyle(AppColors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Topic refresh

    private func refreshTopicsIfNeeded(force: Bool = false) async {
        guard summary.hasEnoughData else { return }
        if isLoadingTopics { return }
        isLoadingTopics = true
        topicError = nil
        let result = await topicAnalyzer.clusters(for: records, forceRefresh: force)
        switch result {
        case .success(let clusters):
            topicClusters = clusters
            lastTopicLoad = Date()
        case .failure(let err):
            topicError = err.errorDescription
            switch err {
            case .noEndpoint:
                topicErrorHeadline = localized("No LLM endpoint configured.", locale: locale)
            case .llmError:
                topicErrorHeadline = localized("Couldn't reach your local LLM.", locale: locale)
            case .parseFailed:
                topicErrorHeadline = localized("Your LLM responded but in an unexpected shape.", locale: locale)
            }
        }
        isLoadingTopics = false
    }

    // MARK: - Formatters

    private func formatInt(_ value: Int) -> String {
        let formatter = NumberFormatter()
        formatter.groupingSeparator = ","
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    private func formatDouble(_ value: Double, digits: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = digits
        formatter.maximumFractionDigits = digits
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    private func formatPercent(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .percent
        formatter.maximumFractionDigits = 0
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }
}
