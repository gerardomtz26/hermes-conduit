//
//  ModelSelectorPill.swift
//  Conduit
//
//  The model selector MOVED out of the composer row (it lived above the
//  text box) into the bar's TRAILING CORNER — build 166: Gerardo asked
//  to move "el selector de modelo y el porcentaje de contexto" to the
//  top-right corner as buttons that open the same way the sessions menu
//  does. The labeled version was his pick: cpu + model / effort + yolo
//  + chevron, so the active model stays visible at a glance.
//
//  While its panel is open this pill is NOT rendered: it is the geometry
//  source the panel inflates from (matched id "model-bubble") — exactly
//  one of the pair exists at any moment, the same contract as the
//  conversation pill and the context ring.
//

import SwiftUI

struct ModelSelectorPill: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let namespace: Namespace.ID
    /// Opens the model panel — injected by MainView so the animated flip
    /// (and the closing of any other panel) lives in one place.
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 6) {
                Image(systemName: "cpu")
                    .foregroundStyle(Color.conduitAccent)
                    .symbolEffect(
                        .variableColor.iterative,
                        options: .repeating,
                        isActive: appState.turnState == .running && !reduceMotion
                    )
                Text(appState.runtime.model.isEmpty ? AppLocalization.string("Model") : appState.runtime.model)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if !appState.runtime.reasoningEffort.isEmpty {
                    Text("/")
                        .foregroundStyle(.secondary)
                    Text(formatEffort(appState.runtime.reasoningEffort))
                        .foregroundStyle(Color.conduitAccent)
                        .lineLimit(1)
                }
                if appState.runtime.yolo {
                    Image(systemName: "shield.slash.fill")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(Color.orange)
                }
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
            }
            .font(.footnote.weight(.semibold))
            // Capped so a long model name cannot balloon the corner
            // group: "mimo-v2.6-flash / medium" fits whole, anything
            // longer truncates in the middle.
            .frame(maxWidth: 200, alignment: .leading)
            .frame(minHeight: 40)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .conduitGlassControl(cornerRadius: 18)
        // Source of the bubble→dropdown morph (see CornerDropdownPanel).
        .matchedGeometryEffect(id: "model-bubble", in: namespace)
        .accessibilityLabel(modelAccessibilityLabel)
        .accessibilityIdentifier("open.model")
        .accessibilityHint("Opens the model selector")
    }

    private func formatEffort(_ value: String) -> String {
        let lower = value.lowercased()
        if lower == "none" || lower == "off" { return AppLocalization.string("Off") }
        if lower == "xhigh" { return AppLocalization.string("Extra High") }
        return lower.capitalized
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
    }

    private var modelAccessibilityLabel: String {
        let model = appState.runtime.model.isEmpty ? AppLocalization.string("Model") : appState.runtime.model
        let reasoning = appState.runtime.reasoningEffort.isEmpty
            ? AppLocalization.string("reasoning not set")
            : AppLocalization.string("reasoning \(formatEffort(appState.runtime.reasoningEffort))")
        let approvals = appState.runtime.yolo ? AppLocalization.string(", auto-approve enabled") : ""
        let activity = appState.turnState == .running ? AppLocalization.string(", agent working") : ""
        return "\(model), \(reasoning)\(approvals)\(activity)"
    }
}
