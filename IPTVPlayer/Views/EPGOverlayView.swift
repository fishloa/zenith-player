import SwiftUI

// MARK: - Constants

private let kPxPerSecond: CGFloat = 800.0 / (6.0 * 3600.0) // ~0.037 pt/sec
private let kMinBlockWidth: CGFloat = 60
private let kChannelColumnWidth: CGFloat = 108
private let kRowHeight: CGFloat = 64
private let kTimeRulerHeight: CGFloat = 36

// MARK: - Colours

private let epgBackground = Color(red: 10/255, green: 10/255, blue: 20/255).opacity(0.96)
private let epgRed = Color(red: 233/255, green: 69/255, blue: 96/255)
private let epgBlockBG = Color(red: 22/255, green: 33/255, blue: 62/255)
private let epgFocusedBG = Color(red: 30/255, green: 42/255, blue: 58/255)
private let epgDivider = Color.white.opacity(0.08)

// MARK: - EPGOverlayView

struct EPGOverlayView: View {
    let channels: [Channel]
    let currentChannel: Channel
    let epgService: EPGService
    var onSwitch: (Channel) -> Void
    var onDismiss: () -> Void

    #if os(tvOS)
    @FocusState private var focusedChannelID: String?
    #else
    @State private var focusedChannelID: String?
    #endif

    private var focusedChannel: Channel? {
        // Keep as computed — drives detail strip reactivity via Observation
        channels.first { $0.id == focusedChannelID }
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            // Dim backdrop
            epgBackground.ignoresSafeArea()

            VStack(spacing: 0) {
                // ── Time ruler ──────────────────────────────────────────
                timeRuler

                Divider().background(epgDivider)

                // ── Channel rows ────────────────────────────────────────
                if epgService.isLoading && epgService.eventsBySlug.isEmpty {
                    Spacer()
                    ProgressView()
                        .progressViewStyle(.circular)
                        .scaleEffect(1.5)
                    Spacer()
                } else if let errorMessage = epgService.error, epgService.eventsBySlug.isEmpty {
                    Spacer()
                    Text(errorMessage)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .padding()
                    Spacer()
                } else {
                    channelList
                }

                Divider().background(epgDivider)

                // ── Detail strip ─────────────────────────────────────────
                detailStrip

                Divider().background(epgDivider)

                // ── Hint bar ─────────────────────────────────────────────
                hintBar
            }
        }
        #if os(tvOS)
        .onExitCommand { onDismiss() }
        #endif
        .onAppear {
            // Set initial focus to the current channel.
            focusedChannelID = currentChannel.id
        }
    }

    // MARK: - Time Ruler

    private var timeRuler: some View {
        HStack(spacing: 0) {
            // "NOW" label in the channel-name column
            Text("NOW")
                .font(.caption.bold())
                .foregroundStyle(epgRed)
                .frame(width: kChannelColumnWidth)

            // Scrollable hour labels — synchronised width with blocks below
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    // Thin red NOW marker at position 0
                    Rectangle()
                        .fill(epgRed)
                        .frame(width: 2, height: kTimeRulerHeight)

                    hourMarkers
                }
            }
            .disabled(true) // ruler is decorative; real scrolling is in rows
        }
        .frame(height: kTimeRulerHeight)
        .background(epgBackground)
    }

    private var hourMarkers: some View {
        let now = Date.now
        let cal = Calendar.current
        // Next whole hour
        var first = cal.nextDate(after: now,
                                  matching: DateComponents(minute: 0, second: 0),
                                  matchingPolicy: .nextTime) ?? now.addingTimeInterval(3600)
        let end = now.addingTimeInterval(6 * 3600)
        var markers: [(offset: CGFloat, label: String)] = []
        while first < end {
            let offset = CGFloat(first.timeIntervalSince(now)) * kPxPerSecond
            let label = hourFormatter.string(from: first)
            markers.append((offset, label))
            first = first.addingTimeInterval(3600)
        }

        return ZStack(alignment: .topLeading) {
            // invisible spacer that gives the ZStack its correct total width
            Color.clear.frame(width: CGFloat(6 * 3600) * kPxPerSecond, height: kTimeRulerHeight)

            ForEach(markers, id: \.offset) { marker in
                Text(marker.label)
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.6))
                    .offset(x: marker.offset + 4)
            }
        }
    }

    // MARK: - Channel List

    private var channelList: some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(spacing: 0) {
                ForEach(channels) { channel in
                    channelRow(channel)
                    Divider().background(epgDivider)
                }
            }
        }
    }

    @ViewBuilder
    private func channelRow(_ channel: Channel) -> some View {
        let isPlaying = channel.id == currentChannel.id
        let isFocused = channel.id == focusedChannelID

        Button {
            if !isPlaying {
                onSwitch(channel)
            }
        } label: {
            HStack(spacing: 0) {
                // ── Left: channel name column ───────────────────────────
                channelLabel(channel, isPlaying: isPlaying, isFocused: isFocused)

                // ── Right: programme blocks ─────────────────────────────
                ScrollView(.horizontal, showsIndicators: false) {
                    programmeBlocks(for: channel.id, isPlaying: isPlaying, isFocused: isFocused)
                        .frame(height: kRowHeight)
                }
            }
            .frame(height: kRowHeight)
            .background(
                isFocused ? epgFocusedBG : epgBackground
            )
            .opacity(isFocused || isPlaying ? 1.0 : 0.5)
            // Red or white left border
            .overlay(alignment: .leading) {
                Rectangle()
                    .fill(isPlaying ? epgRed : (isFocused ? .white : .clear))
                    .frame(width: 3)
            }
        }
        .buttonStyle(.plain)
        #if os(tvOS)
        .focused($focusedChannelID, equals: channel.id)
        #endif
    }

    @ViewBuilder
    private func channelLabel(_ channel: Channel, isPlaying: Bool, isFocused: Bool) -> some View {
        ZStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(channel.name)
                    .font(.caption.bold())
                    .lineLimit(2)
                    .foregroundStyle(isPlaying ? epgRed : (isFocused ? .white : .white.opacity(0.8)))

                if isPlaying {
                    Text("PLAYING")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(epgRed)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(epgRed.opacity(0.2))
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                }
            }
            .padding(.horizontal, 10)
        }
        .frame(width: kChannelColumnWidth, alignment: .leading)
    }

    @ViewBuilder
    private func programmeBlocks(for slug: String, isPlaying: Bool, isFocused: Bool) -> some View {
        let events = epgService.upcomingEvents(for: slug)
        let now = Date.now

        if events.isEmpty {
            HStack {
                Text("No EPG data")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.3))
                    .padding(.leading, 12)
                Spacer()
            }
            .frame(width: CGFloat(6 * 3600) * kPxPerSecond)
        } else {
            ZStack(alignment: .leading) {
                // Background track
                epgBlockBG.opacity(0.3)
                    .frame(width: CGFloat(6 * 3600) * kPxPerSecond)

                ForEach(events, id: \.id) { event in
                    let startOffset = max(0, CGFloat(event.startTime.timeIntervalSince(now)) * kPxPerSecond)
                    let rawWidth = CGFloat(event.durationSecs) * kPxPerSecond
                    // Negative when event started before now — clips the leading edge of the block
                    let leadingOverflow = event.startTime < now
                        ? CGFloat(event.startTime.timeIntervalSince(now)) * kPxPerSecond
                        : 0
                    let clippedWidth = max(kMinBlockWidth, rawWidth + min(0, leadingOverflow))
                    let isCurrent = event.isCurrentlyAiring

                    HStack(spacing: 0) {
                        Text(event.title ?? "")
                            .font(.caption2)
                            .lineLimit(1)
                            .padding(.horizontal, 6)
                            .foregroundStyle(
                                isCurrent && isPlaying ? epgRed :
                                isFocused ? .white :
                                .white.opacity(0.8)
                            )
                    }
                    .frame(width: clippedWidth, height: kRowHeight - 12, alignment: .leading)
                    .background(
                        isCurrent && isPlaying ? epgRed.opacity(0.25) :
                        isFocused ? epgFocusedBG :
                        epgBlockBG
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(
                                isCurrent && isPlaying ? epgRed :
                                isFocused ? Color.white.opacity(0.5) :
                                epgDivider,
                                lineWidth: 1
                            )
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .offset(x: startOffset + 4)
                }
            }
        }
    }

    // MARK: - Detail Strip

    private var detailStrip: some View {
        let channel = focusedChannel ?? currentChannel
        let event = epgService.currentEvent(for: channel.id) ?? epgService.upcomingEvents(for: channel.id).first

        return VStack(alignment: .leading, spacing: 6) {
            if let event {
                Text("\(channel.name) · \(event.title ?? "") · \(timeRangeString(start: event.startTime, stop: event.stopTime))")
                    .font(.callout.bold())
                    .foregroundStyle(.white)
                    .lineLimit(1)

                if let desc = event.description, !desc.isEmpty {
                    Text(desc)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.65))
                        .lineLimit(2)
                }
            } else {
                Text(channel.name)
                    .font(.callout.bold())
                    .foregroundStyle(.white)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 40)
        .padding(.vertical, 14)
        .background(epgBackground)
    }

    // MARK: - Hint Bar

    private var hintBar: some View {
        Group {
            #if os(tvOS)
            Text("↑↓ navigate · ← → scroll time · ▶ switch")
            #else
            Text("Tap a channel to switch · Swipe to scroll")
            #endif
        }
        .font(.caption2)
        .foregroundStyle(.white.opacity(0.4))
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(epgBackground)
    }

    // MARK: - Helpers

    private func timeRangeString(start: Date, stop: Date) -> String {
        "\(hourFormatter.string(from: start)) – \(hourFormatter.string(from: stop))"
    }
}

// MARK: - Formatters (file-private)

private let hourFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "HH:mm"
    return f
}()

