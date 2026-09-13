import ProseAutomation
import SwiftUI

struct AutomationPanel: View {
    @Environment(Workspace.self) private var workspace
    @Environment(\.dismiss) private var dismiss
    @State private var deleting: StoredAutomation?

    private var center: AutomationCenter? { workspace.automations }

    var body: some View {
        NavigationStack {
            Group {
                if let center {
                    List {
                        if let error = center.lastError {
                            Section {
                                Label(error, systemImage: "exclamationmark.triangle")
                                    .foregroundStyle(.orange)
                            }
                        }

                        Section("Automations") {
                            if center.definitions.isEmpty {
                                ContentUnavailableView(
                                    "No Automations",
                                    systemImage: "clock.badge.questionmark",
                                    description: Text(
                                        "Ask an agent to schedule a task, or create a manual recipe."))
                            }
                            ForEach(center.definitions) { item in
                                AutomationRow(item: item, deleting: $deleting)
                            }
                        }

                        Section("Recent Runs") {
                            if center.runs.isEmpty {
                                Text("No runs yet").foregroundStyle(.secondary)
                            }
                            ForEach(center.runs) { run in RunRow(run: run) }
                        }
                    }
                    .task { await center.reload() }
                    .refreshable { await center.reload() }
                } else {
                    ContentUnavailableView(
                        "Automations Unavailable",
                        systemImage: "exclamationmark.triangle",
                        description: Text(workspace.hostFailure ?? "The automation store did not open."))
                }
            }
            .navigationTitle("Automations")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .alert(
            "Delete this automation?",
            isPresented: Binding(
                get: { deleting != nil },
                set: { if !$0 { deleting = nil } })
        ) {
            Button("Cancel", role: .cancel) { deleting = nil }
            Button("Delete", role: .destructive) {
                guard let id = deleting?.id else { return }
                deleting = nil
                Task { _ = try? await center?.change(id: id, action: "delete") }
            }
        } message: {
            Text("Its pending runs and retained history are removed too.")
        }
    }
}

private struct AutomationRow: View {
    let item: StoredAutomation
    @Binding var deleting: StoredAutomation?
    @Environment(Workspace.self) private var workspace

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: item.definition.enabled ? "clock.badge.checkmark" : "pause.circle")
                .foregroundStyle(item.definition.enabled ? Color.accentColor : .secondary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.definition.title)
                Text(triggerSummary(item.definition.trigger, next: item.nextFireAt))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
            Button {
                Task {
                    _ = try? await workspace.automations?.change(
                        id: item.id,
                        action: item.definition.enabled ? "pause" : "resume")
                }
            } label: {
                Image(systemName: item.definition.enabled ? "pause" : "play")
            }
            .help(item.definition.enabled ? "Pause" : "Resume")
            Button {
                Task { _ = try? await workspace.automations?.change(id: item.id, action: "run_now") }
            } label: {
                Image(systemName: "play.fill")
            }
            .help("Run Now")
            Button(role: .destructive) { deleting = item } label: {
                Image(systemName: "trash")
            }
            .help("Delete")
        }
        .buttonStyle(.borderless)
        .padding(.vertical, 3)
    }
}

private struct RunRow: View {
    let run: AutomationRun

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .foregroundStyle(colour)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 3) {
                Text(run.definition.title)
                Text("\(run.state.rawValue) · \(run.scheduledAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if run.attempt > 0 { Text("attempt \(run.attempt)").font(.caption2) }
        }
        .padding(.vertical, 3)
    }

    private var symbol: String {
        switch run.state {
        case .queued: "clock"
        case .running: "arrow.triangle.2.circlepath"
        case .succeeded: "checkmark.circle.fill"
        case .failed, .needsApproval: "exclamationmark.circle.fill"
        case .cancelled: "xmark.circle"
        }
    }

    private var colour: Color {
        switch run.state {
        case .succeeded: .green
        case .failed, .needsApproval: .red
        case .running: .accentColor
        default: .secondary
        }
    }
}

private func triggerSummary(_ trigger: AutomationTrigger, next: Date?) -> String {
    let description: String
    switch trigger {
    case .at(let date):
        description = "Once at \(date.formatted(date: .abbreviated, time: .shortened))"
    case .interval(let every, _):
        let seconds = Int(every)
        if seconds.isMultiple(of: 3600) {
            description = "Every \(seconds / 3600)h"
        } else if seconds.isMultiple(of: 60) {
            description = "Every \(seconds / 60)m"
        } else {
            description = "Every \(seconds)s"
        }
    case .calendar(let rule):
        description = "\(rule.frequency.rawValue.capitalized) at \(String(format: "%02d:%02d", rule.hour, rule.minute)) \(rule.timeZone)"
    case .event(let event):
        description = "On \(event.source).\(event.type)"
    case .manual:
        description = "Manual"
    }
    guard let next else { return description }
    return "\(description) · next \(next.formatted(date: .abbreviated, time: .shortened))"
}
