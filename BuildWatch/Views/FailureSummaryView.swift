import SwiftUI

struct FailureSummaryView: View {
    let push: Push
    @Environment(DashboardViewModel.self) private var viewModel

    var body: some View {
        NavigationStack {
            let groups = viewModel.failureGroups(for: push)
            List {
                if viewModel.failureLinesByPush[push.id] == nil {
                    Section {
                        HStack {
                            ProgressView()
                            Text("Fetching failure details…").foregroundStyle(.secondary)
                        }
                    }
                } else if groups.isEmpty {
                    ContentUnavailableView(
                        "No Failure Details",
                        systemImage: "exclamationmark.triangle",
                        description: Text("TreeHerder has no structured error data for these jobs yet.")
                    )
                } else {
                    Section("\(groups.count) distinct failure\(groups.count == 1 ? "" : "s")") {
                        ForEach(groups) { group in
                            FailureGroupRow(group: group)
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Failure Summary")
            .navigationBarTitleDisplayMode(.inline)
            .task { await viewModel.fetchFailureLines(for: push) }
        }
    }
}

struct FailureGroupRow: View {
    let group: FailureGroup
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.red)
                    .font(.subheadline)
                    .padding(.top, 1)

                VStack(alignment: .leading, spacing: 3) {
                    Text(group.pattern)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(isExpanded ? nil : 2)

                    Label(
                        "\(group.affectedJobCount) job\(group.affectedJobCount == 1 ? "" : "s")",
                        systemImage: "wrench.and.screwdriver"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)

                    if isExpanded {
                        Text(group.exampleLine)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .padding(.top, 2)
                    }
                }

                Spacer()

                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { isExpanded.toggle() }
                } label: {
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 2)
    }
}
