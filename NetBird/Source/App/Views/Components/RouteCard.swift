//
//  RouteCard.swift
//  NetBirdiOS
//
//  Created by Pascal Fischer on 29.06.24.
//

import SwiftUI

struct RouteCard: View {
    @ObservedObject var route: RoutesSelectionInfo
    @Binding var selectedRouteId: UUID?
    @State var orientationTop: Bool
    @ObservedObject var peerViewModel: PeerViewModel
    @ObservedObject var routeViewModel: RoutesViewModel
    
    @State private var tooltipSize: CGSize = .zero
    @GestureState private var isPressing: Bool = false

    var body: some View {
        HStack {
            HStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(statusIndicatorColor)
                    .frame(width: 8, height: 40)

                VStack(alignment: .leading) {
                    Text(route.name)
                        .foregroundColor(Color("TextPeerCard"))
                    if let network = route.network, network.contains("0.0.0.0/0") {
                        Image("direction-sign")
                    }
                }
                .padding(.leading, 5)

                Spacer()

                Text(routeDisplayText)
                    .foregroundColor(Color("TextPeerCard"))
                    .padding(.leading, 3)
            }
            .padding()
            .background(Color("BgPeerCard"))
            .cornerRadius(8)
            .simultaneousGesture(
                TapGesture()
                    .updating($isPressing) { _, gestureState, _ in
                        gestureState = true
                    }
                    .onEnded {
                        if !isPressing {
                            withAnimation {
                                toggleRouteSelection()
                            }
                        }
                    }
            )

            Toggle("", isOn: Binding(
                get: { route.selected },
                set: { newValue in
                    routeViewModel.toggleSelected(for: route.id)
                }
            ))
            .labelsHidden()
            .toggleStyle(SwitchToggleStyle(tint: .orange))
            .onChange(of: route.selected) { newValue in
                newValue ? routeViewModel.selectRoute(route: route) : routeViewModel.deselectRoute(route: route)
            }
            .padding(.trailing, 15)
        }
        .background(Color("BgPeerCard"))
        .cornerRadius(8)
        .overlay(
            GeometryReader { parentGeometry in
                ZStack {
                    if selectedRouteId == route.id {
                        RouteTooltipView(route: route, orientationTop: orientationTop, selectedRouteId: $selectedRouteId)
                            .background(GeometryReader { tooltipGeometry in
                                Color.clear
                                    .onAppear {
                                        tooltipSize = tooltipGeometry.size
                                    }
                            })
                            .position(
                                x: parentGeometry.size.width / 2,
                                y: orientationTop
                                    ? parentGeometry.size.height - (tooltipSize.height / 2) - 50
                                    : (tooltipSize.height / 2) + 50
                            )
                            .opacity(1)
                    }
                }
                .frame(width: parentGeometry.size.width, height: parentGeometry.size.height, alignment: .center)
            },
            alignment: .center
        )
    }

    private var statusIndicatorColor: Color {
        let decision = computeStatusIndicator()
        logIndicatorDecision(decision)
        return decision.color
    }

    private struct IndicatorDecision {
        let color: Color
        let label: String
        let reason: String
    }

    private func computeStatusIndicator() -> IndicatorDecision {
        guard route.selected else {
            return IndicatorDecision(color: Color.gray.opacity(0.5), label: "GRAY", reason: "not selected")
        }

        let connectedPeers = peerViewModel.peerInfo.filter { $0.connStatus == "Connected" }
        guard !connectedPeers.isEmpty else {
            let peerStatusSummary = peerViewModel.peerInfo
                .map { "\($0.fqdn)=\($0.connStatus)" }
                .joined(separator: ",")
            return IndicatorDecision(color: Color.yellow, label: "YELLOW",
                                     reason: "no Connected peer (peers=[\(peerStatusSummary)])")
        }

        let connectedPeerRoutes = connectedPeers.flatMap { $0.routes }

        if let network = route.network, connectedPeerRoutes.contains(network) {
            return IndicatorDecision(color: Color.green, label: "GREEN",
                                     reason: "match \(network) in peer routes")
        }

        let resolvedIPs = (route.domains ?? []).flatMap { $0.resolvedIPs }
        if !resolvedIPs.isEmpty,
           let hit = resolvedIPs.first(where: { connectedPeerRoutes.contains($0) }) {
            return IndicatorDecision(color: Color.green, label: "GREEN",
                                     reason: "resolved IP \(hit) in peer routes")
        }

        return IndicatorDecision(color: Color.yellow, label: "YELLOW",
                                 reason: "no overlap (network=\(route.network ?? "nil") resolvedIPs=\(resolvedIPs) peerRoutes=\(connectedPeerRoutes))")
    }

    private func logIndicatorDecision(_ decision: IndicatorDecision) {
        let key = "\(decision.label)|\(decision.reason)"
        if RouteCard.lastLoggedReasons[route.id] == key { return }
        RouteCard.lastLoggedReasons[route.id] = key

        AppLogger.shared.log("[RouteCard] \(route.name) -> \(decision.label): \(decision.reason)")
    }

    private static var lastLoggedReasons: [UUID: String] = [:]

    private var routeDisplayText: String {
        if let domains = route.domains, !domains.isEmpty {
            if domains.count > 2 {
                return "\(domains.count) Domains"
            }
            return domains.map { $0.domain }.joined(separator: ", ")
        }
        return route.network ?? "Unknown"
    }

    private func toggleRouteSelection() {
        routeViewModel.selectedRouteId = routeViewModel.selectedRouteId == route.id ? nil : route.id
    }
}

struct SizePreferenceKey: PreferenceKey {
    static var defaultValue: CGSize = .zero

    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        value = nextValue()
    }
}

struct RouteTooltipView: View {
    @ObservedObject var route: RoutesSelectionInfo
    @State var orientationTop: Bool
    @Binding var selectedRouteId: UUID?
    
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(route.name)
                .font(.headline)
            Divider()
            detailInfo()
        }
        .padding()
        .background(Color(UIColor.systemGray6))
        .cornerRadius(5)
        .shadow(radius: 5)
        .frame(width: UIScreen.main.bounds.width * 0.8)
        .overlay(
            Triangle()
                .fill(Color(UIColor.systemGray6))
                .frame(width: 20, height: 10)
                .rotationEffect(.degrees(orientationTop ? 180 : 0 ))
                .offset(x: 0, y: orientationTop ? 10 : -10), alignment: orientationTop ? .bottom : .top
        )
        .transition(.identity)
    }
    
    @ViewBuilder
    func detailInfo() -> some View {
        Group {
            if let domains = route.domains, !domains.isEmpty {
                ForEach(domains, id: \.self) { domain in
                    detailRow(label: domain.domain, value: domain.resolvedIPs.joined(separator: ", "))
                }
            } else {
                detailRow(label: "Network", value: route.network ?? "")
            }
        }
        .font(.footnote)
    }
    
    @ViewBuilder
    func detailRow(label: String, value: String) -> some View {
        HStack {
            Text("\(label):").bold()
            Spacer()
            Text(value)
                .multilineTextAlignment(.leading)
                .foregroundColor(.gray)
                .fixedSize(horizontal: false, vertical: true)
        }
    }  
    
    struct Triangle: Shape {
        func path(in rect: CGRect) -> Path {
            var path = Path()
            path.move(to: CGPoint(x: rect.midX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
            path.closeSubpath()
            return path
        }
    }
    
}


