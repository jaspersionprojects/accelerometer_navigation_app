//
//  ContentView.swift
//  ANav
//
//  Created by Jasper Sion on 17/03/2026.
//

import MapKit
import SwiftUI

struct ContentView: View {
    @StateObject private var viewModel = NavigationViewModel()

    var body: some View {
        ZStack(alignment: .bottom) {
            Map(position: $viewModel.cameraPosition) {
                ForEach(viewModel.annotations) { annotation in
                    Annotation(annotation.title, coordinate: annotation.coordinate, anchor: .bottom) {
                        AnnotationBadge(annotation: annotation)
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

            VStack(spacing: 14) {
                Text(viewModel.statusText)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: Capsule())

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
                    Spacer(minLength: 0)
                }

                HStack(spacing: 18) {
                    LegendItem(label: "GPS", color: Color(red: 0.13, green: 0.56, blue: 0.95))
                    LegendItem(label: "Inertial", color: Color(red: 0.97, green: 0.45, blue: 0.15))
                    Spacer()
                    Button(action: viewModel.recenterMap) {
                        Label("Recenter", systemImage: "scope")
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.plain)
                    Text(viewModel.referenceFrameText)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
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
            .padding(16)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.35), lineWidth: 1)
            )
            .padding(.horizontal, 16)
            .padding(.bottom, 20)
        }
        .onAppear(perform: viewModel.start)
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
