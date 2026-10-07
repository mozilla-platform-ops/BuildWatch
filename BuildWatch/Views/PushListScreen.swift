import SwiftUI

/// "Ryan's pushes": the simple view's push list (`PushList.jsx`).
struct PushListScreen: View {
    @Environment(DashboardViewModel.self) private var viewModel
    @State private var editing = false

    var body: some View {
        let author = viewModel.username
        let name = viewModel.authorName

        SimplePage(
            fullView: URL(string: "https://treeherder.mozilla.org/jobs?repo=try&author=\(author.urlQueryEscaped)")!,
            refresh: { await viewModel.refresh() }
        ) {
            AuthorEditor(author: author, name: name, editing: $editing)
        } content: {
            HStack(alignment: .bottom, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(Strings.List.title(name))
                        .svFont(34, .bold)
                        .tracking(-0.68)
                        .accessibilityAddTraits(.isHeader)
                    if name != nil {
                        Text(author)
                            .svFont(14)
                            .foregroundStyle(SV.muted)
                    }
                }
                Spacer(minLength: 0)
                Kit()
            }
            .padding(.horizontal, 6)
            .padding(.bottom, 24)
            .svRise()

            if viewModel.errorMessage != nil {
                Text(Strings.List.unreachable)
                    .svFont(16)
                    .foregroundStyle(SV.muted)
                    .padding(.horizontal, 6)
            } else if viewModel.pushes.isEmpty && !viewModel.isRefreshing && viewModel.lastRefresh != nil {
                VStack(alignment: .leading, spacing: 0) {
                    Text(Strings.List.empty(author))
                        .svFont(16)
                        .foregroundStyle(SV.muted)
                    Button(Strings.List.wrongAddress) { editing = true }
                        .svFont(14)
                        .foregroundStyle(SV.link)
                        .frame(minHeight: 48)
                }
                .padding(.horizontal, 6)
                .svRise()
            }

            LazyVStack(spacing: 8) {
                ForEach(Array(viewModel.pushes.enumerated()), id: \.element.id) { index, push in
                    NavigationLink(value: Route.push(push)) {
                        PushRow(push: push)
                    }
                    .buttonStyle(PressStyle())
                    .svRise(index: index)
                    .task {
                        async let summary: Void = viewModel.fetchHealthSummary(for: push)
                        await viewModel.fetchJobs(for: push)
                        await summary
                    }
                    .contextMenu {
                        let watched = viewModel.watchedPushIds.contains(push.id)
                        Button(watched ? "Stop watching" : Strings.Watch.idle,
                               systemImage: watched ? "bell.slash" : "bell") {
                            viewModel.toggleWatch(push: push)
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Row

/// `.sv-row`: a mini ring, the push's title, one line of status, and how long ago.
private struct PushRow: View {
    let push: Push
    @Environment(DashboardViewModel.self) private var viewModel

    var body: some View {
        let health = viewModel.healthSummaries[push.id]
        let status = viewModel.summary(for: push)?.ringStatus ?? health?.status
        let described = SimpleView.describe(health, status: status)
        let watched = viewModel.watchedPushIds.contains(push.id)

        HStack(spacing: 12) {
            TickRing(status: health == nil ? nil : status, ticks: 24, size: 38, weight: 7)
            VStack(alignment: .leading, spacing: 6) {
                Text(push.displayTitle)
                    .svFont(16, .bold)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                HStack(spacing: 12) {
                    if health != nil {
                        Text(described.text)
                            .svFont(14, .bold)
                            .foregroundStyle(described.tone.text)
                    } else {
                        Skeleton(width: 126, height: 14)
                    }
                    Spacer(minLength: 0)
                    if watched {
                        Image(systemName: "bell.fill")
                            .svFont(12)
                            .foregroundStyle(SV.muted)
                    }
                    Text(SimpleView.ago(push.date))
                        .svFont(14)
                        .foregroundStyle(SV.muted)
                        .lineLimit(1)
                }
                .frame(minHeight: 20)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .foregroundStyle(SV.ink)
        .padding(.leading, 12)
        .padding(.trailing, 14)
        .padding(.vertical, 12)
        .svCard()
        .modifier(Pulse(key: health == nil ? nil : "\(described.text)", tone: described.tone))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([
            push.displayTitle,
            health == nil ? "loading" : described.text,
            SimpleView.ago(push.date),
            watched ? "watched" : nil,
        ].compactMap { $0 }.joined(separator: ", "))
        .accessibilityHint("Opens this push")
    }
}

/// `.sv-pulse`: a ring of the row's tone that fades out when its status changes.
private struct Pulse: ViewModifier {
    let key: String?
    let tone: Tone
    @State private var glow = false

    func body(content: Content) -> some View {
        content
            .overlay(
                RoundedRectangle(cornerRadius: SV.radius + 2)
                    .stroke(tone.color, lineWidth: 3)
                    .padding(-2)
                    .opacity(glow ? 1 : 0)
            )
            .onChange(of: key) { old, new in
                guard old != nil, new != nil, old != new else { return }
                glow = true
                withAnimation(.easeOut(duration: 1.2)) { glow = false }
            }
    }
}

// MARK: - Author

/// "author: Ryan Curran ✎" in the info bar; tap it to type a different address.
private struct AuthorEditor: View {
    let author: String
    let name: String?
    @Binding var editing: Bool
    @Environment(DashboardViewModel.self) private var viewModel
    @State private var value = ""
    @FocusState private var focused: Bool

    var body: some View {
        if editing {
            let next = value.trimmingCharacters(in: .whitespaces).lowercased()
            FlowLayout(spacing: 8, lineSpacing: 8) {
                TextField(Strings.Picker.emailLabel, text: $value)
                    .textFieldStyle(.plain)
                    .keyboardType(.emailAddress)
                    .textContentType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($focused)
                    .submitLabel(.go)
                    .onSubmit { submit(next) }
                    .svFont(16)
                    .foregroundStyle(SV.ink)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .frame(minWidth: 180)
                    .background(SV.surface, in: RoundedRectangle(cornerRadius: SV.radius))
                    .overlay(RoundedRectangle(cornerRadius: SV.radius).strokeBorder(SV.hairline))
                inlineButton(Strings.List.editShow, filled: true) { submit(next) }
                    .disabled(!next.contains("@"))
                    .opacity(next.contains("@") ? 1 : 0.4)
                inlineButton(Strings.List.editCancel) { editing = false }
                NavigationLink(value: Route.people) {
                    Text(Strings.List.editRecent)
                        .padding(.horizontal, 12)
                        .frame(minHeight: 40)
                }
            }
            .padding(.vertical, 6)
            .onAppear {
                value = author
                focused = true
            }
        } else {
            Button {
                editing = true
            } label: {
                HStack(spacing: 4) {
                    Text(Strings.List.author(name ?? author))
                    Text("✎").fontWeight(.regular).opacity(0.8)
                }
                .frame(minHeight: 36)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Strings.List.authorLabel(author))
        }
    }

    private func submit(_ next: String) {
        guard next.contains("@") else { return }
        editing = false
        viewModel.show(author: next)
    }

    private func inlineButton(_ title: String, filled: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .foregroundStyle(filled ? .white : SV.infoInk)
                .padding(.horizontal, 12)
                .frame(minHeight: 40)
                .background(filled ? SV.link : .clear, in: RoundedRectangle(cornerRadius: SV.radius))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Picker

/// "Pushes by…": recent people, or type an address (`AuthorPrompt.jsx`).
struct PeoplePicker: View {
    var canGoBack = false
    var onChoose: () -> Void = {}
    @Environment(DashboardViewModel.self) private var viewModel
    @State private var email = ""

    var body: some View {
        let valid = email.contains("@")

        SimplePage(
            backLabel: canGoBack ? Strings.List.title(viewModel.authorName) : nil,
            fullView: URL(string: "https://treeherder.mozilla.org/jobs?repo=try")!
        ) {
            VStack(alignment: .leading, spacing: 16) {
                Text(Strings.Picker.title)
                    .svFont(30, .bold)
                    .tracking(-0.6)
                    .accessibilityAddTraits(.isHeader)

                if !viewModel.people.isEmpty {
                    HStack {
                        Text(Strings.Picker.recent).svCaps()
                        Spacer()
                        Button(Strings.Picker.clear) { viewModel.clearPeople() }
                            .svFont(14)
                            .foregroundStyle(SV.link)
                            .frame(minHeight: 44)
                    }
                    VStack(spacing: 8) {
                        ForEach(viewModel.people, id: \.email) { person in
                            Button { choose(person.email) } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(person.name ?? person.email).svFont(17, .bold)
                                    if person.name != nil {
                                        Text(person.email).svFont(13).foregroundStyle(SV.muted)
                                    }
                                }
                                .foregroundStyle(SV.ink)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(16)
                                .svCard()
                            }
                            .buttonStyle(PressStyle())
                        }
                    }
                    .padding(.horizontal, -6)
                    .padding(.top, -10)
                }

                VStack(spacing: 10) {
                    TextField(Strings.Picker.placeholder(!viewModel.people.isEmpty), text: $email)
                        .keyboardType(.emailAddress)
                        .textContentType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.go)
                        .onSubmit { if valid { choose(email) } }
                        .svFont(17)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 14)
                        .background(SV.surface, in: RoundedRectangle(cornerRadius: SV.radius))
                        .overlay(RoundedRectangle(cornerRadius: SV.radius).strokeBorder(SV.hairline))
                        .accessibilityLabel(Strings.Picker.emailLabel)

                    Button { choose(email) } label: {
                        Text(Strings.Picker.show)
                            .svFont(16, .bold)
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(14)
                            .background(SV.link, in: RoundedRectangle(cornerRadius: SV.radius))
                    }
                    .buttonStyle(PressStyle(scale: 0.97))
                    .disabled(!valid)
                    .opacity(valid ? 1 : 0.4)
                }

                OutlineButton(title: Strings.Picker.openFullView, size: 16, padding: 14) {
                    openURL(URL(string: "https://treeherder.mozilla.org/jobs?repo=try")!)
                }
            }
            .padding(.horizontal, 6)
            .svRise()
        }
    }

    @Environment(\.openURL) private var openURL

    private func choose(_ address: String) {
        viewModel.show(author: address)
        onChoose()
    }
}

/// `.sv-button-secondary` / `.sv-action`: a white button with a blue outline.
struct OutlineButton: View {
    let title: String
    var muted = false
    var filled = false
    var size: CGFloat = 15
    var padding: CGFloat = 12
    var fullWidth = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .svFont(size, muted ? .regular : .bold)
                .multilineTextAlignment(.center)
                .foregroundStyle(filled ? .white : muted ? SV.muted : SV.link)
                .frame(maxWidth: fullWidth ? .infinity : nil)
                .padding(.horizontal, 22)
                .padding(.vertical, padding)
                .frame(minHeight: 48)
                .background(filled ? SV.link : SV.surface, in: RoundedRectangle(cornerRadius: SV.radius))
                .overlay(RoundedRectangle(cornerRadius: SV.radius).strokeBorder(muted ? SV.hairline : SV.link))
        }
        .buttonStyle(PressStyle(scale: 0.97))
    }
}

extension String {
    var urlQueryEscaped: String {
        addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed.subtracting(CharacterSet(charactersIn: "@+&=")))
            ?? self
    }
}
