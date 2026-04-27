import SwiftUI

struct TryPushesView: View {
    @State private var viewModel = DashboardViewModel()

    var body: some View {
        NavigationStack {
            Group {
                if viewModel.username.isEmpty {
                    noUsernameView
                } else if viewModel.isRefreshing && viewModel.pushes.isEmpty {
                    loadingView
                } else if let error = viewModel.errorMessage, viewModel.pushes.isEmpty {
                    errorView(error)
                } else if !viewModel.isRefreshing && viewModel.pushes.isEmpty {
                    emptyView
                } else {
                    pushList
                }
            }
            .navigationTitle(viewModel.usernameHandle)
            .navigationBarTitleDisplayMode(.large)
            .toolbar { toolbarContent }
            .task {
                guard !viewModel.username.isEmpty else { return }
                await viewModel.refresh()
            }
        }
        .environment(viewModel)
    }

    // MARK: - Push List

    private var pushList: some View {
        List {
            ForEach(viewModel.pushes) { push in
                NavigationLink(destination: PushDetailView(push: push)) {
                    PushRowView(push: push)
                }
                .task { await viewModel.fetchJobs(for: push) }
            }
        }
        .listStyle(.plain)
        .refreshable { await viewModel.refresh() }
    }

    // MARK: - Empty States

    private var loadingView: some View {
        VStack(spacing: 16) {
            ProgressView().scaleEffect(1.5)
            Text("Loading pushes…").foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyView: some View {
        ContentUnavailableView(
            "No Try Pushes",
            systemImage: "tray",
            description: Text("No recent try pushes found for \(viewModel.username).")
        )
    }

    private var noUsernameView: some View {
        ContentUnavailableView {
            Label("Set Your Mozilla Email", systemImage: "person.crop.circle")
        } description: {
            Text("Add your Mozilla email in Settings to view your try pushes.")
        }
    }

    private func errorView(_ message: String) -> some View {
        ContentUnavailableView {
            Label("Couldn't Load Pushes", systemImage: "wifi.exclamationmark")
        } description: {
            Text(message)
        } actions: {
            Button("Try Again") { Task { await viewModel.refresh() } }
                .buttonStyle(.borderedProminent)
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .navigationBarTrailing) {
            HStack(spacing: 12) {
                if let last = viewModel.lastRefresh {
                    Text(last.shortTimeAgo())
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if viewModel.isRefreshing {
                    ProgressView().scaleEffect(0.8)
                } else {
                    Button {
                        Task { await viewModel.refresh() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(viewModel.username.isEmpty)
                }
            }
        }
    }
}

// MARK: - Push Row

struct PushRowView: View {
    let push: Push
    @Environment(DashboardViewModel.self) private var viewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(push.displayTitle)
                .font(.subheadline.weight(.medium))
                .lineLimit(2)

            HStack(spacing: 8) {
                Text(push.authorHandle)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer()

                PlatformStatusDots(
                    groups: viewModel.platformGroups(for: push),
                    isLoading: viewModel.jobsByPush[push.id] == nil
                )

                statusBadge

                Text(push.date.shortTimeAgo())
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var statusBadge: some View {
        let failures = viewModel.failureCount(push)
        if failures > 0 {
            Text("\(failures)")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.red, in: Capsule())
        } else if viewModel.isRunning(push) {
            Image(systemName: "arrow.trianglehead.clockwise.rotate.90")
                .font(.caption)
                .foregroundStyle(.blue)
                .symbolEffect(.rotate)
        } else if viewModel.jobsByPush[push.id] != nil {
            Image(systemName: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
        }
    }
}

// MARK: - Platform Status Dots

struct PlatformStatusDots: View {
    let groups: [PlatformGroup]
    let isLoading: Bool

    var body: some View {
        HStack(spacing: 4) {
            if isLoading {
                ForEach(0..<5, id: \.self) { _ in
                    Circle()
                        .fill(Color(uiColor: .systemGray5))
                        .frame(width: 8, height: 8)
                }
            } else {
                ForEach(groups.prefix(8)) { group in
                    Circle()
                        .fill(group.overallStatus.color)
                        .frame(width: 8, height: 8)
                        .help(group.displayName)
                }
            }
        }
    }
}
