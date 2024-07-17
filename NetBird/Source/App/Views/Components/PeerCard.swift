//
//  PeerCard.swift
//  NetBirdiOS
//
//  Created by Pascal Fischer on 10.10.23.
//

import SwiftUI

struct PeerCard: View {
    @ObservedObject var peer: PeerInfo
    @Binding var selectedPeerId: UUID?
    @State var orientationTop: Bool
    
    @State private var tooltipSize: CGSize = .zero
    
    var body: some View {
        HStack {
            HStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(peer.connStatus == "Connected" ? Color.green : Color.gray.opacity(0.5))
                                .frame(width: 8, height: 40)
                VStack(alignment: .leading, content: {
                    Text(peer.fqdn).padding(.bottom, 1).foregroundColor(Color("TextPeerCard"))
                    Text(peer.ip).foregroundColor(Color("TextPeerCard"))
                }).padding(.leading, 5)
                if(peer.routes.contains("0.0.0.0/0")){
                    Image("direction-sign")
                }
                Spacer()
                Text(peer.connStatus).foregroundColor(Color("TextPeerCard")).padding(.leading, 3)
            }
            .padding()
        }.background(
            Color("BgPeerCard")
        )
        .cornerRadius(8)
        .overlay(
            GeometryReader { parentGeometry in
                ZStack {
                    if selectedPeerId == peer.id {
                        PeerTooltipView(peer: peer, orientationTop: orientationTop, selectedPeerId: $selectedPeerId)
                            .background(GeometryReader { tooltipGeometry in
                                Color.clear
                                    .onAppear {
                                        tooltipSize = tooltipGeometry.size
                                    }
                            })
                            .position(
                                x: parentGeometry.size.width / 2,
                                y: orientationTop ? parentGeometry.size.height - (tooltipSize.height / 2) - 65 : (tooltipSize.height / 2) + 65
                            )
                            .opacity(self.selectedPeerId == peer.id ? 1 : 0)
                    }
                }
                .frame(width: parentGeometry.size.width, height: parentGeometry.size.height, alignment: .center)
            },
            alignment: .center
        )
    }
}

struct PeerTooltipView: View {
    @ObservedObject var peer: PeerInfo
    @State var orientationTop: Bool
    @Binding var selectedPeerId: UUID?
    
    @State var relativeDateText: String = ""

    private let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }()

    private let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter
    }()
    
    func updateRelativeDate(from dateString: String) {
        if dateString == "0001-01-01 00:00:00" {
            relativeDateText = "never"
            return
        }
        
        if let date = dateFormatter.date(from: dateString) {
            relativeDateText = relativeFormatter.localizedString(for: date, relativeTo: Date())
        } else {
            relativeDateText = dateString
        }
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(peer.fqdn)
                .font(.headline)
            Divider()
            detailInfo()
        }
        .padding()
        .background(Color(UIColor.systemGray6))
        .cornerRadius(5)
        .shadow(radius: 5)
        .frame(width: UIScreen.main.bounds.width * 0.8)
        .onChange(of: selectedPeerId, perform: { value in
            self.updateRelativeDate(from: peer.connStatusUpdate)
        })
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
            detailRow(label: "Public key", value: peer.pubKey)
            detailRow(label: "Status", value: peer.connStatus)
            detailRow(label: "Last status update", value: relativeDateText)
            detailRow(label: "Connection type", value: peer.relayed ? "Relayed" : "P2P")
            detailRow(label: "Direct", value: peer.direct.description)
            detailRow(label: "ICE candidate (Local/Remote)", value: "\(peer.localIceCandidateType)/\(peer.remoteIceCandidateType)")
            iceEndpointsRow(label: "ICE endpoints (Local/Remote)", local: peer.localIceCandidateEndpoint, remote: peer.remoteIceCandidateEndpoint)
            detailRow(label: "Quantum resistance", value: peer.rosenpassEnabled.description)
            detailRow(label: "Latency", value: peer.latency)
            routesRow(label: "Routes", value: peer.routes)
            
        }
        .font(.footnote)
    }
    
    @ViewBuilder
    func detailRow(label: String, value: String) -> some View {
        HStack {
            Text("\(label):").bold()
            Spacer()
            Text(value).foregroundColor(.gray)
        }
    }  
    
    @ViewBuilder
    func iceEndpointsRow(label: String, local: String, remote: String) -> some View {
        VStack {
            HStack {
                Text("\(label):").bold()
                Spacer()
            }
            HStack {
                Spacer()
                Text("\(local)/\(remote)").foregroundColor(.gray)
            }
        }
    }
    
    @ViewBuilder
    func routesRow(label: String, value: [String]) -> some View {
        VStack(alignment: .leading) {
            HStack {
                Text("\(label):").bold()
                if value.count == 0 || value.count > 9 {
                    Spacer()
                    Text("\(value.count) Routes").foregroundColor(.gray)
                } else if value.count <= 2 {
                    Spacer()
                    Text("[\(value.joined(separator: ", "))]")
                        .multilineTextAlignment(.leading)
                        .lineLimit(3) // Allow unlimited lines or set a specific number like 10 if needed
                        .foregroundColor(.gray)
                        .fixedSize(horizontal: false, vertical: true) // Ensures the text can grow vertically
                }
            }
            if value.count > 2 && value.count <= 9 {
                HStack {
                    Spacer()
                    Text("[\(value.joined(separator: ", "))]")
                        .multilineTextAlignment(.leading)
                        .lineLimit(3) // Allow unlimited lines or set a specific number like 10 if needed
                        .foregroundColor(.gray)
                        .fixedSize(horizontal: false, vertical: true) // Ensures the text can grow vertically
                }
            }
        }
    }
    
    func formatDateRelative(from dateString: String) -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.timeZone = TimeZone(secondsFromGMT: 0)

        guard let date = dateFormatter.date(from: dateString) else {
            return dateString
        }

        let relativeFormatter = RelativeDateTimeFormatter()
        relativeFormatter.unitsStyle = .full

        let relativeDate = relativeFormatter.localizedString(for: date, relativeTo: Date())
        return relativeDate
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


