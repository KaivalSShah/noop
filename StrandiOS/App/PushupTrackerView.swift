import SwiftUI
import Combine
import StrandDesign

// MARK: - Push-up tracker (iOS)
//
// A big tap target that adds one push-up to TODAY per tap, a deliberate Undo for a mistaken tap, the
// headline figures (today / this week / total / streak), and a contribution-style history graph: one
// column per week, one row per weekday, shaded by that day's count. Tapping a past square shows −/+ to
// correct that day. All data lives in the local-only `PushupLogStore` (UserDefaults JSON, one entry per
// logical day — rolling at 04:00 like Today, so a late-night set counts toward the evening before).
struct PushupTrackerView: View {
    @ObservedObject private var store = PushupLogStore.shared
    @Environment(\.scenePhase) private var scenePhase

    /// The instant "today" resolves against. Refreshed on appear, on each tap, when the app returns to
    /// the foreground and by a minute tick, so a screen left open past the 04:00 rollover moves on.
    @State private var now = Date()
    /// The history square the user tapped, by day key; nil shows the hint line.
    @State private var selectedKey: String?

    /// A year of history, GitHub-style. Wider than a phone, so the graph scrolls and opens on today.
    private static let weeksShown = 53

    private var calendar: Calendar { store.calendar }
    private var todayKey: String { PushupDay.key(for: PushupDay.today(at: now, calendar: calendar), calendar: calendar) }
    private var todayCount: Int { store.counts[todayKey] ?? 0 }

    /// Only the logical day changing matters, so the tick doesn't re-render the screen every minute.
    private func refreshNow() {
        let fresh = Date()
        if PushupDay.key(for: PushupDay.today(at: fresh, calendar: calendar), calendar: calendar) != todayKey {
            now = fresh
        }
    }

    var body: some View {
        ScreenScaffold(title: "Push-ups",
                       subtitle: "Tap once per rep. Saved on this device only.",
                       topBackground: liquidScaffoldSky()) {
            VStack(alignment: .leading, spacing: NoopMetrics.sectionGap) {
                counterSection
                summarySection
                historySection
            }
        }
        .onAppear { now = Date() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { refreshNow() }
        }
        .onReceive(Timer.publish(every: 60, on: .main, in: .common).autoconnect()) { _ in
            refreshNow()
        }
    }

    // MARK: - Counter

    private var counterSection: some View {
        NoopCard {
            VStack(spacing: 18) {
                Text("Today").strandOverline()

                Button(action: addOne) {
                    ZStack {
                        Circle().fill(StrandPalette.accent.opacity(0.16))
                        Circle().strokeBorder(StrandPalette.accent, lineWidth: 3)
                        VStack(spacing: 4) {
                            Text(todayCount, format: .number)
                                .font(StrandFont.rounded(72, weight: .bold))
                                .monospacedDigit()
                                .foregroundStyle(StrandPalette.textPrimary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.5)
                                .contentTransition(.numericText(value: Double(todayCount)))
                            Text("Tap to count")
                                .font(StrandFont.subhead)
                                .foregroundStyle(StrandPalette.textSecondary)
                        }
                        .padding(28)
                    }
                    .frame(width: 236, height: 236)
                    .contentShape(Circle())
                }
                .buttonStyle(LiquidPressStyle())
                .accessibilityLabel(Text("Add one push-up"))
                .accessibilityValue(Text(todayCount, format: .number))

                NoopButton("Undo", systemImage: "arrow.uturn.backward", kind: .secondary) { removeOne() }
                    .disabled(todayCount == 0)
                    .accessibilityLabel(Text("Remove one push-up"))
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func addOne() {
        refreshNow()
        withAnimation(.easeOut(duration: 0.18)) { _ = store.increment() }
        StrandHaptic.light.play()
    }

    private func removeOne() {
        refreshNow()
        withAnimation(.easeOut(duration: 0.18)) { _ = store.decrement() }
        StrandHaptic.selection.play()
    }

    // MARK: - Summary

    private var summarySection: some View {
        let summary = PushupSummary.compute(counts: store.counts, now: now, calendar: calendar)
        return NoopCard {
            HStack(spacing: 0) {
                pushupStat("Today", summary.today)
                pushupStat("This week", summary.thisWeek)
                pushupStat("Total", summary.total)
                pushupStat("Streak", summary.currentStreak)
            }
        }
    }

    private func pushupStat(_ label: LocalizedStringKey, _ value: Int) -> some View {
        VStack(spacing: 4) {
            Text(value, format: .number)
                .font(StrandFont.number(22))
                .foregroundStyle(StrandPalette.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(label)
                .font(StrandFont.caption)
                .foregroundStyle(StrandPalette.textSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }

    // MARK: - History

    private var historySection: some View {
        let grid = PushupGrid.build(weeks: Self.weeksShown, endingAt: now, calendar: calendar)
        return NoopCard {
            VStack(alignment: .leading, spacing: NoopMetrics.gap) {
                Text("History").strandOverline()
                PushupContributionGraph(grid: grid,
                                        counts: store.counts,
                                        maxCount: grid.maxCount(in: store.counts),
                                        calendar: calendar,
                                        selectedKey: $selectedKey)
                legend
                selectedDayLine
            }
        }
    }

    private var legend: some View {
        HStack(spacing: 4) {
            Spacer(minLength: 0)
            Text("Less")
                .font(StrandFont.caption)
                .foregroundStyle(StrandPalette.textTertiary)
            ForEach(0...PushupIntensity.maxLevel, id: \.self) { level in
                RoundedRectangle(cornerRadius: PushupContributionGraph.cornerRadius, style: .continuous)
                    .fill(PushupContributionGraph.color(forLevel: level))
                    .frame(width: PushupContributionGraph.cellSize, height: PushupContributionGraph.cellSize)
            }
            Text("More")
                .font(StrandFont.caption)
                .foregroundStyle(StrandPalette.textTertiary)
        }
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var selectedDayLine: some View {
        if let key = selectedKey, let date = PushupDay.date(forKey: key, calendar: calendar) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(date, format: .dateTime.weekday(.abbreviated).month(.abbreviated).day().year())
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textSecondary)
                Spacer(minLength: 8)
                let count = store.counts[key] ?? 0
                dayStepButton("minus", label: "Remove one push-up", enabled: count > 0) {
                    _ = store.decrement(on: date)
                }
                Text(count, format: .number)
                    .font(StrandFont.bodyNumber)
                    .foregroundStyle(StrandPalette.textPrimary)
                    .contentTransition(.numericText(value: Double(count)))
                Text("Push-ups")
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textSecondary)
                dayStepButton("plus", label: "Add one push-up", enabled: key <= todayKey) {
                    _ = store.increment(on: date)
                }
            }
        } else {
            Text("Tap a square to see that day.")
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)
        }
    }

    /// A small −/+ that corrects the selected day's total, e.g. to move a set logged on the wrong day.
    private func dayStepButton(_ symbol: String, label: LocalizedStringKey, enabled: Bool,
                               action: @escaping () -> Void) -> some View {
        Button {
            withAnimation(.easeOut(duration: 0.18)) { action() }
            StrandHaptic.selection.play()
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(enabled ? StrandPalette.accent : StrandPalette.textTertiary)
                .frame(width: 32, height: 32)
                .background(Circle().fill(StrandPalette.accent.opacity(enabled ? 0.16 : 0.06)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(Text(label))
    }
}

// MARK: - Contribution graph

/// The GitHub-style grid: weekday labels pinned on the left, then a horizontally scrolling block of
/// month labels over week columns of rounded squares. Opens scrolled to the newest week.
private struct PushupContributionGraph: View {
    let grid: PushupGrid
    let counts: [String: Int]
    let maxCount: Int
    let calendar: Calendar
    @Binding var selectedKey: String?

    static let cellSize: CGFloat = 13
    static let spacing: CGFloat = 3
    static let cornerRadius: CGFloat = 3
    private static let monthRowHeight: CGFloat = 14
    private static let monthRowGap: CGFloat = 4
    /// Room above/below the squares so today's outline and the selected square's lift aren't clipped.
    private static let outlineInset: CGFloat = 2

    /// Empty, then four increasing shades of the user's accent colour.
    static func color(forLevel level: Int) -> Color {
        switch level {
        case ..<1: return StrandPalette.surfaceInset
        case 1: return StrandPalette.accent.opacity(0.30)
        case 2: return StrandPalette.accent.opacity(0.52)
        case 3: return StrandPalette.accent.opacity(0.76)
        default: return StrandPalette.accent
        }
    }

    private var columnWidth: CGFloat { Self.cellSize + Self.spacing }

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            weekdayLabels
            ScrollView(.horizontal, showsIndicators: false) {
                VStack(alignment: .leading, spacing: Self.monthRowGap) {
                    monthLabels
                    HStack(alignment: .top, spacing: Self.spacing) {
                        ForEach(grid.weeks.indices, id: \.self) { col in
                            VStack(spacing: Self.spacing) {
                                ForEach(0..<7, id: \.self) { row in
                                    cell(grid.weeks[col][row])
                                }
                            }
                        }
                    }
                }
                .padding(.vertical, Self.outlineInset)
                .padding(.horizontal, Self.outlineInset)
            }
            .defaultScrollAnchor(.trailing)
        }
    }

    /// Mon / Wed / Fri, on whichever rows those weekdays fall for the calendar's first weekday.
    private var weekdayLabels: some View {
        VStack(alignment: .trailing, spacing: Self.monthRowGap) {
            Color.clear.frame(width: 1, height: Self.monthRowHeight)
            VStack(alignment: .trailing, spacing: Self.spacing) {
                ForEach(0..<7, id: \.self) { row in
                    let weekday = PushupGrid.weekday(forRow: row, calendar: calendar)
                    Text(verbatim: [2, 4, 6].contains(weekday) ? calendar.shortWeekdaySymbols[weekday - 1] : "")
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .lineLimit(1)
                        .fixedSize()
                        .frame(height: Self.cellSize)
                }
            }
        }
        .padding(.vertical, Self.outlineInset)
        .accessibilityHidden(true)
    }

    private var monthLabels: some View {
        ZStack(alignment: .topLeading) {
            Color.clear
                .frame(width: CGFloat(grid.weeks.count) * columnWidth, height: Self.monthRowHeight)
            ForEach(grid.monthLabels, id: \.column) { label in
                Text(verbatim: calendar.shortMonthSymbols[label.month - 1])
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .lineLimit(1)
                    .fixedSize()
                    .offset(x: CGFloat(label.column) * columnWidth)
            }
        }
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func cell(_ cell: PushupGrid.Cell?) -> some View {
        if let cell {
            let count = counts[cell.key] ?? 0
            let level = PushupIntensity.level(count: count, maxCount: maxCount)
            let isToday = cell.key == grid.todayKey
            let isSelected = cell.key == selectedKey
            RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                .fill(Self.color(forLevel: level))
                .frame(width: Self.cellSize, height: Self.cellSize)
                .overlay {
                    if isToday || isSelected {
                        RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                            .strokeBorder(StrandPalette.textPrimary, lineWidth: isSelected ? 2 : 1.5)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    selectedKey = isSelected ? nil : cell.key
                    StrandHaptic.selection.play()
                }
                .accessibilityElement()
                .accessibilityLabel(Text(cell.date, format: .dateTime.weekday(.wide).month(.wide).day().year()))
                .accessibilityValue(Text(count, format: .number))
                .accessibilityAddTraits(.isButton)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
        } else {
            Color.clear.frame(width: Self.cellSize, height: Self.cellSize)
        }
    }
}
