//
//  ContentView.swift
//  ANav
//
//  Created by Jasper Sion on 17/03/2026.
//

import Combine
import MapKit
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var viewModel = NavigationViewModel()
    @State private var isPanelMinimized = false
    @State private var panelHeight: CGFloat = 0
    @GestureState private var panelDragTranslation: CGFloat = 0
    @State private var selectedPanelPage = 0
    @State private var isExportingCSV = false
    @State private var csvExportDocument = CSVExportDocument(text: "")
    @State private var csvExportFilename = "ANav-log"

    var body: some View {
        ZStack(alignment: .bottom) {
            MapReader { proxy in
                Map(position: $viewModel.cameraPosition) {
                    if viewModel.areTrailsVisible {
                        if viewModel.gpsTrailCoordinates.count >= 2 {
                            MapPolyline(coordinates: viewModel.gpsTrailCoordinates)
                                .stroke(Color(red: 0.13, green: 0.56, blue: 0.95), lineWidth: 4)
                        }

                        if viewModel.inertialTrailCoordinates.count >= 2 {
                            MapPolyline(coordinates: viewModel.inertialTrailCoordinates)
                                .stroke(Color(red: 0.97, green: 0.45, blue: 0.15), style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
                        }
                    }

                    ForEach(viewModel.annotations) { annotation in
                        Annotation(annotation.title, coordinate: annotation.coordinate, anchor: .bottom) {
                            AnnotationBadge(annotation: annotation)
                        }
                    }

                    if viewModel.isRoadConfidenceVisible,
                       let coordinate = viewModel.displayedRoadConfidenceCoordinate,
                       let confidenceText = viewModel.roadConfidenceText {
                        Annotation("Road Confidence", coordinate: coordinate, anchor: .center) {
                            RoadConfidenceBadge(text: confidenceText)
                        }
                    }
                }
                .overlay {
                    if viewModel.isPlacingInertialPin {
                        ZStack(alignment: .top) {
                            Color.clear
                                .contentShape(Rectangle())
                                .gesture(
                                    SpatialTapGesture()
                                        .onEnded { value in
                                            if let coordinate = proxy.convert(value.location, from: .local) {
                                                viewModel.placeInertialMarker(at: coordinate)
                                            }
                                        }
                                )

                            Text("Tap the map to place the inertial marker")
                                .font(.footnote.weight(.semibold))
                                .padding(.horizontal, 14)
                                .padding(.vertical, 10)
                                .background(.ultraThinMaterial, in: Capsule())
                                .padding(.top, 72)
                        }
                    }
                }
                .simultaneousGesture(
                    DragGesture(minimumDistance: 1)
                        .onChanged { _ in
                            viewModel.handleMapInteraction()
                        }
                )
                .simultaneousGesture(
                    MagnifyGesture()
                        .onChanged { _ in
                            viewModel.handleMapInteraction()
                        }
                )
                .ignoresSafeArea()
            }

            VStack(spacing: 14) {
                Capsule()
                    .fill(Color.secondary.opacity(0.45))
                    .frame(width: 42, height: 5)
                    .padding(.top, 2)
                    .onTapGesture {
                        withAnimation(.spring(response: 0.28, dampingFraction: 0.84)) {
                            isPanelMinimized.toggle()
                        }
                    }

                TabView(selection: $selectedPanelPage) {
                    VStack(spacing: 14) {
                        HStack(spacing: 10) {
                            ForEach(MovementMode.allCases) { mode in
                                Button(action: { viewModel.setMovementMode(mode) }) {
                                    Label(mode.title, systemImage: mode.systemImage)
                                        .font(.caption2.weight(.semibold))
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 9)
                                        .lineLimit(1)
                                        .minimumScaleFactor(0.75)
                                        .foregroundStyle(viewModel.movementMode == mode ? .white : .primary)
                                        .background(
                                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                                .fill(
                                                    viewModel.movementMode == mode
                                                        ? Color(red: 0.15, green: 0.22, blue: 0.34)
                                                        : Color.white.opacity(0.55)
                                                )
                                        )
                                }
                                .buttonStyle(.plain)
                            }
                        }

                        HStack(spacing: 12) {
                            StatCard(
                                title: "GPS Speed",
                                value: viewModel.gpsSpeedText,
                                accent: Color(red: 0.13, green: 0.56, blue: 0.95)
                            )
                            StatCard(
                                title: "Inertial Speed",
                                value: viewModel.inertialSpeedText,
                                accent: Color(red: 0.97, green: 0.45, blue: 0.15)
                            )
                        }

                        HStack(spacing: 12) {
                            StatCard(
                                title: "Heading",
                                value: viewModel.headingText,
                                accent: Color(red: 0.46, green: 0.35, blue: 0.85)
                            )
                            StatCard(
                                title: "GPS Gap",
                                value: viewModel.markerSeparationText,
                                accent: Color(red: 0.16, green: 0.67, blue: 0.54)
                            )
                        }

                        HStack(spacing: 10) {
                            MainPanelActionButton(
                                title: viewModel.isLoggingSessionActive ? "Logging..." : "Start Log",
                                systemImage: "record.circle",
                                tint: Color(red: 0.80, green: 0.16, blue: 0.20),
                                isEmphasized: viewModel.isLoggingSessionActive
                            ) {
                                viewModel.startCSVLogging()
                            }
                            .disabled(viewModel.isLoggingSessionActive)
                            .opacity(viewModel.isLoggingSessionActive ? 0.75 : 1)

                            MainPanelActionButton(
                                title: "Stop Log",
                                systemImage: "stop.circle",
                                tint: Color(red: 0.31, green: 0.33, blue: 0.39),
                                isEmphasized: false
                            ) {
                                viewModel.stopCSVLogging()
                            }
                            .disabled(!viewModel.isLoggingSessionActive)
                            .opacity(viewModel.isLoggingSessionActive ? 1 : 0.55)
                        }

                        Button(action: viewModel.snapToGPS) {
                            Label("Snap To GPS", systemImage: "location.circle.fill")
                                .font(.headline.weight(.semibold))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                                .foregroundStyle(.white)
                                .background(
                                    LinearGradient(
                                        colors: [
                                            Color(red: 0.96, green: 0.53, blue: 0.18),
                                            Color(red: 0.83, green: 0.31, blue: 0.09)
                                        ],
                                        startPoint: .leading,
                                        endPoint: .trailing
                                    ),
                                    in: RoundedRectangle(cornerRadius: 18, style: .continuous)
                                )
                        }
                        .buttonStyle(.plain)
                        .disabled(!viewModel.canSnapToGPS)
                        .opacity(viewModel.canSnapToGPS ? 1 : 0.55)
                    }
                    .tag(0)
                    .padding(.horizontal, 2)

                    VStack(spacing: 14) {
                        Text("Inertial Settings")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)

                        InertialActionButton(action: viewModel.startCalibration) {
                            Label(
                                viewModel.isCalibrationRunning
                                    ? "Calibrating..."
                                    : (viewModel.hasCompletedManualCalibration ? "Recalibrate" : "Calibrate"),
                                systemImage: viewModel.hasCompletedManualCalibration ? "checkmark.circle" : "sensor.tag.radiowaves.forward"
                            )
                            .font(.caption.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                        }
                        .disabled(viewModel.isCalibrationRunning)
                        .opacity(viewModel.isCalibrationRunning ? 0.7 : 1)

                        HStack(spacing: 10) {
                            InertialActionButton(action: viewModel.resetInertialSpeed) {
                                Label("Reset Inertial", systemImage: "arrow.counterclockwise")
                                    .font(.caption.weight(.semibold))
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 10)
                            }

                            InertialActionButton(action: {
                                if viewModel.isPlacingInertialPin {
                                    viewModel.cancelPlacingInertialPin()
                                } else {
                                    viewModel.startPlacingInertialPin()
                                }
                            }) {
                                Label(viewModel.isPlacingInertialPin ? "Cancel Pin" : "Place Pin", systemImage: viewModel.isPlacingInertialPin ? "xmark.circle" : "mappin.and.ellipse")
                                    .font(.caption.weight(.semibold))
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 10)
                            }
                        }

                        HStack(spacing: 10) {
                            InertialActionButton(action: viewModel.showTrails) {
                                Label("Show Trails", systemImage: "scribble")
                                    .font(.caption.weight(.semibold))
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 10)
                            }

                            InertialActionButton(action: viewModel.hideTrails) {
                                Label("Hide Trails", systemImage: "eye.slash")
                                    .font(.caption.weight(.semibold))
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 10)
                            }
                        }

                        InertialActionButton(action: viewModel.toggleRoadConfidenceVisibility) {
                            Label(
                                viewModel.isRoadConfidenceVisible ? "Hide Road Confidence" : "Show Road Confidence",
                                systemImage: viewModel.isRoadConfidenceVisible ? "eye.slash.circle" : "road.lanes.curved.left"
                            )
                            .font(.caption.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                        }

                        InertialActionButton(action: viewModel.clearTrails) {
                            Label("Clear Trails", systemImage: "trash")
                                .font(.caption.weight(.semibold))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 10)
                        }
                    }
                    .tag(1)
                    .padding(.horizontal, 2)
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .frame(height: 346)

                HStack(spacing: 8) {
                    ForEach(0..<2, id: \.self) { page in
                        Circle()
                            .fill(selectedPanelPage == page ? Color.primary : Color.secondary.opacity(0.35))
                            .frame(width: 7, height: 7)
                    }
                }
            }
            .padding(16)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.35), lineWidth: 1)
            )
            .background(
                GeometryReader { geometry in
                    Color.clear
                        .preference(key: PanelHeightPreferenceKey.self, value: geometry.size.height)
                }
            )
            .onPreferenceChange(PanelHeightPreferenceKey.self) { panelHeight = $0 }
            .offset(y: panelOffset)
            .gesture(panelDragGesture)
            .animation(.spring(response: 0.28, dampingFraction: 0.84), value: isPanelMinimized)
            .padding(.horizontal, 16)
            .padding(.bottom, 20)
        }
        .fileExporter(
            isPresented: $isExportingCSV,
            document: csvExportDocument,
            contentType: .commaSeparatedText,
            defaultFilename: csvExportFilename
        ) { result in
            viewModel.handleCSVExportCompletion(result)
        }
        .onReceive(viewModel.$pendingCSVExport.compactMap { $0 }) { payload in
            csvExportDocument = CSVExportDocument(text: payload.csvText)
            csvExportFilename = payload.fileName
            isExportingCSV = true
        }
        .onAppear(perform: viewModel.start)
    }

    private var minimizedOffset: CGFloat {
        max(panelHeight - 74, 0)
    }

    private var panelOffset: CGFloat {
        let restingOffset = isPanelMinimized ? minimizedOffset : 0
        return min(max(restingOffset + panelDragTranslation, 0), minimizedOffset)
    }

    private var panelDragGesture: some Gesture {
        DragGesture(minimumDistance: 8)
            .updating($panelDragTranslation) { value, state, _ in
                state = value.translation.height
            }
            .onEnded { value in
                let shouldMinimize = value.translation.height > 60
                let shouldMaximize = value.translation.height < -60

                withAnimation(.spring(response: 0.28, dampingFraction: 0.84)) {
                    if shouldMinimize {
                        isPanelMinimized = true
                    } else if shouldMaximize {
                        isPanelMinimized = false
                    }
                }
            }
    }
}

private struct PanelHeightPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct CSVExportDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.commaSeparatedText] }

    var text: String

    init(text: String) {
        self.text = text
    }

    init(configuration: ReadConfiguration) throws {
        if let data = configuration.file.regularFileContents,
           let text = String(data: data, encoding: .utf8) {
            self.text = text
        } else {
            self.text = ""
        }
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}

private struct StatCard: View {
    let title: String
    let value: String
    let accent: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 26, weight: .bold, design: .rounded))
                .foregroundStyle(.primary)
                .minimumScaleFactor(0.8)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

private struct MainPanelActionButton: View {
    let title: String
    let systemImage: String
    let tint: Color
    let isEmphasized: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.caption.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .foregroundStyle(isEmphasized ? .white : .primary)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(isEmphasized ? tint : tint.opacity(0.13))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(tint.opacity(isEmphasized ? 0 : 0.3), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }
}

private struct TrailActionButtonStyle: ButtonStyle {
    var isFlashed = false

    func makeBody(configuration: Configuration) -> some View {
        let isActive = configuration.isPressed || isFlashed

        configuration.label
            .foregroundStyle(.primary)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(
                        isActive
                            ? Color(red: 0.92, green: 0.84, blue: 0.72)
                            : Color.white.opacity(0.55)
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(
                        isActive
                            ? Color(red: 0.79, green: 0.48, blue: 0.16)
                            : Color.white.opacity(0.4),
                        lineWidth: isActive ? 1.5 : 1
                    )
            )
            .shadow(
                color: .black.opacity(isActive ? 0.06 : 0.14),
                radius: isActive ? 2 : 8,
                y: isActive ? 1 : 4
            )
            .scaleEffect(isActive ? 0.93 : 1)
            .offset(y: isActive ? 1 : 0)
            .animation(.spring(response: 0.18, dampingFraction: 0.72), value: isActive)
    }
}

private struct InertialActionButton<Label: View>: View {
    let action: () -> Void
    @ViewBuilder let label: () -> Label

    @State private var isFlashing = false

    var body: some View {
        Button(action: triggerAction) {
            label()
        }
        .buttonStyle(TrailActionButtonStyle(isFlashed: isFlashing))
    }

    private func triggerAction() {
        withAnimation(.spring(response: 0.18, dampingFraction: 0.72)) {
            isFlashing = true
        }

        action()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) {
            withAnimation(.spring(response: 0.22, dampingFraction: 0.78)) {
                isFlashing = false
            }
        }
    }
}

private struct LegendItem: View {
    let label: String
    let color: Color

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(color)
                .frame(width: 10, height: 10)
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
        }
    }
}

private struct RoadConfidenceBadge: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption2.weight(.bold))
            .foregroundStyle(.primary)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(
                Capsule()
                    .strokeBorder(Color.orange.opacity(0.45), lineWidth: 1)
            )
    }
}

private struct AnnotationBadge: View {
    let annotation: NavigationAnnotation

    var body: some View {
        VStack(spacing: 6) {
            Text(annotation.title)
                .font(.caption2.weight(.bold))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.ultraThinMaterial, in: Capsule())

            Image(systemName: annotation.systemImage)
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .background(annotation.color, in: Circle())
                .overlay(
                    Circle()
                        .strokeBorder(Color.white.opacity(0.9), lineWidth: 2)
                )
                .shadow(color: annotation.color.opacity(0.35), radius: 8, y: 4)
        }
    }
}
